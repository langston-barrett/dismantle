{-# LANGUAGE TypeOperators #-}
{-|
Module           : Dismantle.ARM.XML
Copyright        : (c) Galois, Inc 2019-2020
Maintainer       : Daniel Matichuk <dmatichuk@galois.com>

This module processes the XML specification published by
ARM and produces an 'Encoding' for each opcode encoding.

Each 'Encoding' is later associated with an instruction/encoding
pair from the ARM Specification Language (ASL) by "Dismantle.ARM.ASL"
and used to derive a 'DT.InstructionDescriptor'.

The top-level interface is provided by 'loadEncodings' which builds
a list of 'Encoding's.
-}

{-# OPTIONS_HADDOCK prune #-}
{-# LANGUAGE GADTs, DataKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ConstraintKinds #-}

module Dismantle.ARM.XML
  ( loadEncodings
  , encodingOpToInstDescriptor
  , instDescriptorsToISA
  , EncodedForm(..)
  , Operand(..)
  , Encoding(..)
  , Field(..)
  , xmlFieldNameToASL
  , getOperandDescriptors
  -- FIXME: likely implemented elsewhere
  , fromListWithM
  ) where

import           Prelude hiding (fail)
import           GHC.TypeLits

import           System.FilePath ( takeFileName )

import           Control.Applicative ( (<|>) )
import qualified Control.Exception as E
import           Control.Monad.Except ( throwError )
import qualified Control.Monad.Except as ME
import           Control.Monad ( forM, forM_, void, unless, foldM, (>=>) )
import           Control.Monad.Fail ( fail )
import qualified Control.Monad.Fail as MF
import           Control.Monad.Trans ( lift, liftIO )
import qualified Control.Monad.State as MS
import qualified Control.Monad.Reader as R
import           Control.Monad.Trans.RWS.Strict ( RWST )
import qualified Control.Monad.Trans.RWS.Strict as RWS

import           Data.Word ( Word8 )
import qualified Data.List as List
import qualified Data.List.Split as List
import qualified Data.Set as S
import qualified Data.Map as M
import           Data.Maybe (catMaybes, fromMaybe, isJust, listToMaybe, maybeToList)
import qualified Data.Parameterized.Classes as PC
import qualified Data.Parameterized.NatRepr as NR
import           Data.PropTree ( PropTree )
import qualified Data.PropTree as PropTree
import           Text.Printf (printf)
import qualified Data.Text.IO as TIO

import qualified Text.Megaparsec as P
import qualified Text.Megaparsec.Char as P
import qualified Text.XML.Light as X
import           Text.PrettyPrint.HughesPJClass ( (<+>), ($$) )
import qualified Text.PrettyPrint.HughesPJClass as PP

import qualified Dismantle.Tablegen.Parser.Types as PT
import qualified Dismantle.Tablegen.Patterns as BT
import qualified Dismantle.Tablegen as DT

import           Data.BitMask (BitSection, QuasiBit, BitMask )
import qualified Data.BitMask as BM

type IsMaskBit a = (BM.MaskBit a, Show a)

data XMLException = MissingChildElement String
                       | NoMatchingChildElement
                       | MissingAttr String
                       | forall n . MissingField String (NR.NatRepr n) (Fields n)
                       | MissingEncoding String
                       | InvalidChildElement
                       | MnemonicError String
                       | InvalidPattern String
                       | forall n . MismatchedFieldWidth (NR.NatRepr n) (Field n) Int
                       | forall a n . IsMaskBit a => MismatchedFieldsForBits (NR.NatRepr n) [NameExp (Field n)] [a]
                       | forall a. Show a => MismatchedWidth String Int [a]
                       | InvalidXmlFile String
                       | forall e. (Show e, P.ShowErrorComponent e) => InnerParserFailure (P.ParseErrorBundle String e)
                       | UnexpectedAttributeValue String String
                       | forall n . InvalidField (NR.NatRepr n) (Field n)
                       | forall n . FieldMergeError (NR.NatRepr n) (Field n) (Field n) String
                       | BitdiffsParseError String String
                       | UnexpectedBitfieldLength [BT.Bit]
                       | NoUniqueiClass String
                       | MissingXMLFile String
                       | forall n . InvalidConstraints (NR.NatRepr n) (PropTree (BitSection n QuasiBit)) String
                       | XMLMonadFail String
                       | forall a b. (IsMaskBit a, IsMaskBit b) => MismatchedListLengths [a] [b]
                       | UnexpectedElements [X.Element]
                       | MissingEncodingTableEntry String
                       | forall n . MismatchedMasks EncodedForm (NR.NatRepr n) (BitMask n QuasiBit) (BitMask n QuasiBit)
                       | forall n . MismatchedNegativeMasks EncodedForm (NR.NatRepr n) [BitMask n BT.Bit] [BitMask n BT.Bit]
                       | forall a n . IsMaskBit a => InvalidBitsForBitsection (NR.NatRepr n) Int [a]
                       | UnexpectedForm String


deriving instance Show XMLException

instance E.Exception OuterXMLException

data OuterXMLException = OuterXMLException XMLEnv XMLException

newtype XML a = XML (RWST XMLEnv () XMLState (ME.ExceptT OuterXMLException IO) a)
  deriving ( Functor
           , Applicative
           , Monad
           , MS.MonadState XMLState
           , R.MonadReader XMLEnv
           , MS.MonadIO
           )

instance MF.MonadFail XML where
  fail msg = throwError $ XMLMonadFail msg

instance ME.MonadError XMLException XML where
  throwError e = do
    env <- R.ask
    XML (lift $ throwError $ OuterXMLException env e)

  catchError (XML m) handler = do
    st <- MS.get
    env <- R.ask
    result <- liftIO $ ME.runExceptT $ RWS.runRWST m env st
    case result of
      Left (OuterXMLException _ e) -> handler e
      Right (a, st', ()) -> do
        MS.put st'
        return a

warnError :: XMLException -> XML ()
warnError e = do
  env <- R.ask
  let pretty = PP.nest 1 (PP.text "WARNING:" $$ (PP.pPrint $ OuterXMLException env e))
  logXML $ PP.render pretty

prettyMask :: BM.MaskBit bit => EncodedForm -> BitMask n bit -> PP.Doc
prettyMask efrm mask = BM.prettySegmentedMask (endianness efrm) mask

instance PP.Pretty XMLException where
  pPrint e = case e of
    UnexpectedElements elems ->
      PP.text "UnexpectedElements"
      <+> PP.brackets (PP.hsep (PP.punctuate (PP.text ",") (map simplePrettyElem elems)))
    MismatchedMasks efrm _nr mask mask' -> PP.text "MismatchedMasks"
      $$ PP.nest 1 (prettyMask efrm mask $$ prettyMask efrm mask')
    MismatchedNegativeMasks efrm _nr masks masks' -> PP.text "MismatchedNegativeMasks"
      $$ PP.nest 1 (PP.vcat (map (prettyMask efrm) masks))
      $$ PP.text "vs."
      $$ PP.nest 1 (PP.vcat (map (prettyMask efrm) masks'))
    InnerParserFailure e' -> PP.text "InnerParserFailure"
      $$ PP.nest 1 (PP.vcat $ (map PP.text $ lines (P.errorBundlePretty e')))
    _ -> PP.text $ show e

instance PP.Pretty OuterXMLException where
  pPrint (OuterXMLException env e) =
    PP.text "Error encountered while processing" <+> PP.text (xmlArchName env)
    <+> case xmlCurrentFile env of
      Just curFile -> PP.text "in" <+> PP.text curFile
      Nothing -> PP.empty
    <+> case xmlCurrentEncoding env of
      Just curEnc -> PP.text "for encoding" <+> PP.text curEnc
      Nothing -> PP.empty
    <+> (if (null (xmlCurrentPath env)) then PP.empty else PP.text "at XML path:")
    $$ PP.nest 1 (prettyElemPath $ xmlCurrentPath env)
    $$ PP.nest 1 (PP.pPrint e)


prettyElemPath :: [X.Element] -> PP.Doc
prettyElemPath es = go (reverse es)
  where
    go :: [X.Element] -> PP.Doc
    go [e] = simplePrettyElem e <+> (case X.elLine e of
      Just l -> PP.text "| line:" <+> PP.int (fromIntegral l)
      Nothing -> PP.empty)
    go (e : es') = simplePrettyElem e $$ (PP.nest 1 $ go es')
    go [] = PP.empty

simplePrettyElem :: X.Element -> PP.Doc
simplePrettyElem e = PP.text "<" PP.<> PP.text (X.qName (X.elName e))
  <+> (PP.hsep $ map prettyAttr (X.elAttribs e))
  PP.<> PP.text ">"
  where
    prettyAttr :: X.Attr -> PP.Doc
    prettyAttr at =
      PP.text (X.qName (X.attrKey at))
      PP.<> PP.text "="
      PP.<> PP.doubleQuotes (PP.text (X.attrVal at))

instance Show OuterXMLException where
  show e = PP.render (PP.pPrint e)


data InstructionLeaf = InstructionLeaf { ileafFull :: X.Element -- entire leaf
                                       , ileafiClass :: X.Element -- iclass
                                       }
  deriving Show

data SomeEncodingMasks where
  SomeEncodingMasks :: NR.NatRepr n -> BitMask n QuasiBit -> [BitMask n BT.Bit] -> SomeEncodingMasks

deriving instance Show SomeEncodingMasks

data XMLState = XMLState { encodingMap :: M.Map String Encoding
                         , encodingTableMap :: M.Map EncIndexIdent SomeEncodingMasks
                         }

  deriving Show

data XMLEnv = XMLEnv { xmlCurrentFile :: Maybe FilePath
                     , xmlCurrentEncoding :: Maybe String
                     , xmlCurrentPath :: [X.Element]
                     , xmlAllFiles :: [FilePath]
                     , xmlArchName :: String
                     , xmlLog :: String -> IO ()
                     }

runXML :: String -> [FilePath] -> (String -> IO ()) -> XML a -> IO (Either OuterXMLException a)
runXML archName allFiles logf (XML a) = ME.runExceptT $
    fst <$> RWS.evalRWST a (XMLEnv Nothing Nothing [] allFiles archName logf) (XMLState M.empty M.empty)


qname :: String -> X.QName
qname str = X.QName str Nothing Nothing

-- | Build a list of 'Encoding's from the XML specification
loadEncodings :: String
              -- ^ the name of the architecture (either "A32" or "T32")
              -> [FilePath]
              -- ^ list of all xml files from the ARM specification
              -> FilePath
              -- ^ the encoding index file from the ARM specification, providing
              -- additional decoding information
              -> (String -> IO ())
              -- ^ function for logging while parsing the XML
              -> IO [Encoding]
loadEncodings arch xmlFiles xmlEncIndex logFn = do
  result <- runXML arch xmlFiles logFn $ do
    withParsedXMLFile xmlEncIndex loadEncIndex
    encodings <- fmap concat $ forM xmlFiles $ (\f -> withParsedXMLFile f loadInstrs)
    forM_ encodings $ \encoding ->
      logXML $ PP.render $ PP.pPrint encoding
    return encodings
  case result of
    Left err -> do
      logFn (show err)
      E.throw err
    Right desc -> return desc

logXML :: String -> XML ()
logXML msg = do
  logf <- R.asks xmlLog
  MS.liftIO (logf msg)

withParsedXMLFile :: FilePath -> (X.Element -> XML a) -> XML a
withParsedXMLFile fullPath m = R.local (\e -> e { xmlCurrentFile = Just fullPath }) $ do
  fileStr <- MS.liftIO $ TIO.readFile fullPath
  case X.parseXMLDoc fileStr of
    Just c -> withElement c $ m c
    Nothing -> throwError $ InvalidXmlFile fullPath

withEncodingName :: String -> XML a -> XML a
withEncodingName encnm = R.local (\e -> e { xmlCurrentEncoding = Just encnm })

withElement :: X.Element -> XML a -> XML a
withElement xelem = R.local (\e -> e { xmlCurrentPath = xelem : (xmlCurrentPath e) })

data EncIndexIdent =
    IdentEncodingName String
  | IdentFileClassName String FilePath
  deriving (Show, Eq, Ord)

getEncIndexIdent :: X.Element -> XML EncIndexIdent
getEncIndexIdent elt = case X.findAttr (qname "encname") elt of
  Just nm -> return $ IdentEncodingName nm
  Nothing -> do
    encoding <- getAttr "encoding" elt
    iformfile <- getAttr "iformfile" elt
    return $ IdentFileClassName encoding iformfile

getDecodeConstraints :: NR.NatRepr n -> Fields n -> X.Element -> XML (PropTree (BitSection n BT.Bit))
getDecodeConstraints nr fields dcs = do
  rawConstraints <- forChildren "decode_constraint" dcs $ \dc -> do
    [name,"!=", val] <- getAttrs ["name", "op", "val"] dc
    flds <- nameExps name
    bits <- parseString (P.some bitParser) val
    return $ PropTree.negate $ PropTree.clause $ (flds, bits)
  resolvePropTree nr fields (mconcat rawConstraints)

instrTableConstraints :: NR.NatRepr n -> [[NameExp (Field n)]] -> X.Element -> XML (PropTree (BitSection n BT.Bit))
instrTableConstraints nr tablefieldss tr = do
  "instructiontable" <- getAttr "class" tr
  let tds = X.filterChildren (\e -> X.findAttr (qname "class") e == Just "bitfield") tr
  fmap mconcat $ forM (zip tds [0..]) $ \(td, i) -> do
    let fields = tablefieldss !! i
    let width = sum $ map slicedFieldWidth fields
    bitwidth <- read <$> getAttr "bitwidth" td
    -- soft-throw this error since the XML is occasionally wrong but this is recoverable
    unless (width == bitwidth) $
      warnError $ MismatchedWidth "instrTableConstraints" bitwidth fields
    fmap PropTree.collapse $ parseConstraint width (X.strContent td) $ \bits -> do
      unpackFieldConstraints nr (fields, bits)

loadEncIndex :: X.Element -> XML ()
loadEncIndex encodingindex = do
  arch <- R.asks xmlArchName
  isa <- getAttr "instructionset" encodingindex
  unless (arch == isa) $
    throwError $ UnexpectedAttributeValue "instructionset" isa
  void $ forChildren "iclass_sect" encodingindex addEncodingTableMapEntry

addEncodingTableMapEntry :: X.Element -> XML ()
addEncodingTableMapEntry iclass_sect = do
  FieldsAndConstraints _efrm nr fields _ fieldConstraints <- iclassFieldsAndProp iclass_sect
  decodeConstraints <- withChild "decode_constraints" iclass_sect $ \case
    Just dcs -> getDecodeConstraints nr fields dcs
    Nothing -> return mempty
  instructiontable <- getChild "instructiontable" iclass_sect
  bitfieldsElts <- resolvePath instructiontable $
    [ ("thead", Just ("class", "instructiontable"))
    , ("tr", Just ("id", "heading2")) ]
  fieldss <- case bitfieldsElts of
    [] -> return []
    [bitfieldsElt] -> forChildren "th" bitfieldsElt $ \th -> do
      "bitfields" <- getAttr "class" th
      nmes <- nameExps (X.strContent th)
      mapM (lookupField nr fields) nmes
    _ -> throwError $ UnexpectedElements bitfieldsElts
  tbody <- getChild "tbody" instructiontable
  void $ forChildren "tr" tbody $ \tr -> do
    encident <- getEncIndexIdent tr
    constraints <- instrTableConstraints nr fieldss tr
    (mask, negMasks) <- deriveMasks nr fieldConstraints (decodeConstraints <> constraints)
    MS.modify' $ \st -> st { encodingTableMap = M.insert encident (SomeEncodingMasks nr mask (List.nub negMasks)) (encodingTableMap st)
                           }
    return ()
  return ()

loadInstrs :: X.Element -> XML [Encoding]
loadInstrs xmlElement = do
  -- format as instructions
  arch <- R.asks xmlArchName
  withChild "classes" xmlElement $ \case
    Just classes -> do
      fmap concat $ forChildren "iclass" classes $ \iclass -> do
        let leaf = InstructionLeaf xmlElement iclass
        isa <- getAttr "isa" iclass
        if isa == arch && not (isAliasedInstruction leaf) then do
          FieldsAndConstraints efrm nr fields qmasks iconstraints <- iclassFieldsAndProp iclass
          leafGetEncodings efrm leaf nr fields qmasks iconstraints
        else return []
    _ -> return []

-- FIXME: does not belong here.
fromListWithM :: forall m k a. Ord k => Monad m => (a -> a -> m a) -> [(k, a)] -> m (M.Map k a)
fromListWithM f l = sequence $ M.fromListWith doMerge $ map (\(k, a) -> (k, return a)) l
  where
    doMerge :: m a -> m a -> m a
    doMerge m1 m2 = do
      a1 <- m1
      a2 <- m2
      f a1 a2

data FieldsAndConstraints where
  FieldsAndConstraints :: (1 <= n) => EncodedForm -> NR.NatRepr n -> Fields n -> BitSection n () -> PropTree (BitSection n QuasiBit) -> FieldsAndConstraints

-- | Examine a "regdiagram" element and compute the NatRepr corresponding to the
-- stated width.  Instruction width is one of 16, 16x2, or 32.  The NatRepr will
-- either be 16 (in the first case) or 32.
--
-- Example:
--
-- > <regdiagram form="16" psname="aarch32/instrs/ADD_i/T1_A.txt">
-- > </regdiagram>
withEncodingSize :: X.Element -> (forall n . (1 <= n) => EncodedForm -> NR.NatRepr n -> XML a) -> XML a
withEncodingSize regdiagram k = do
  form <- getAttr "form" regdiagram
  case form of
    "16" -> k Thumb1Form (NR.knownNat @16)
    "32" -> k ARMForm (NR.knownNat @32)
    "16x2" -> k Thumb2Form (NR.knownNat @32)
    _ -> withElement regdiagram (throwError (UnexpectedForm form))

iclassFieldsAndProp :: X.Element -> XML FieldsAndConstraints
iclassFieldsAndProp iclass = do
  -- NOTE: Here we know the width of the instruction based on the `form` field of the `regdiagram`
  --
  -- If the form="16", we have a 16 bit T1 encoding.  Otherwise, it is a 32 bit encoding (either T2 or A)
  --
  -- We can compute the NatRepr here and pass it everywhere, ultimately embedding it in the return value
  rd <- getChild "regdiagram" iclass
  withEncodingSize rd $ \efrm nr -> do
    fields <- forChildren "box" rd (getBoxField nr)
    namedFields <- fmap catMaybes $ forM fields $ \field -> do
      case (fieldName field, fieldUseName field) of
        (_ : _, True) -> return $ Just (fieldName field, field)
        (_, False) -> return Nothing
        _ -> throwError $ InvalidField nr field
    namedMap <- fromListWithM (mergeFields nr) namedFields
    return $ FieldsAndConstraints efrm nr namedMap (quasiMaskOfFields nr fields) (mconcat (map fieldConstraint fields))

mergeFields :: (1 <= n) => NR.NatRepr n -> Field n -> Field n -> XML (Field n)
mergeFields nr field1 field2 = case mergeFields' nr field1 field2 of
  Left msg -> throwError $ FieldMergeError nr field1 field2 msg
  Right result -> return result

mergeFields' :: (ME.MonadError String m, 1 <= n) => NR.NatRepr n -> Field n -> Field n -> m (Field n)
mergeFields' nr field1 field2 =
  if field1 == field2 then return field1 else do
  unless (fieldName field1 == fieldName field2) $
    ME.throwError $ "different field names"

  let constraint = fieldConstraint field1 <> fieldConstraint field2
  (mask, _) <- BM.deriveMasks nr (fmap (fmap BM.JustBit) constraint)
  (hiBit, width) <- case BM.asContiguousSections (BM.maskAsBitSection mask) of
    [(posBit, BM.SomeBitMask bmask)] ->
      return $ (fromIntegral (NR.intValue nr) - 1 - posBit, BM.lengthInt bmask)
    _ -> ME.throwError $ "not contiguous"
  return $ Field { fieldName = fieldName field1
                 , fieldHibit = hiBit
                 , fieldWidth = width
                 , fieldConstraint = constraint
                 , fieldUseName = fieldUseName field1 || fieldUseName field2
                 }

constraintParser :: Parser ([BT.Bit], Bool)
constraintParser = do
  isPositive <- (P.chunk "!= " >> return False) <|> (return True)
  bits <- P.some bitParser
  return (bits, isPositive)

parseConstraint :: Int -> String -> ([BT.Bit] -> XML a) -> XML (PropTree a)
parseConstraint width "" m = PropTree.clause <$> m (replicate width BT.Any)
parseConstraint width str m = do
  (bits, isPositive) <- parseString constraintParser str
  unless (length bits == width) $
    throwError $ MismatchedWidth "parseConstraint" width bits
  let sign = if isPositive then id else PropTree.negate
  sign . PropTree.clause <$> m bits

fieldBeginOffset :: NR.NatRepr n -> Int -> Int
fieldBeginOffset nr i
  | Just PC.Refl <- PC.testEquality nr (NR.knownNat @16) = i - 16
  | otherwise = i

getBoxField :: NR.NatRepr n -> X.Element -> XML (Field n)
getBoxField nr box = do
  let width = maybe 1 read (X.findAttr (qname "width") box)
  -- NOTE: The bit indices coming from the XML are all relative to bit 31, even
  -- on 16 bit instructions.  We need to correct for that here for 16 bit
  -- instructions.  We do it as early as possible to ensure consistency.
  hibit <- fieldBeginOffset nr <$> read <$> getAttr "hibit" box

  constraint <- case X.findAttr (qname "constraint") box of
    Just constraint -> do
      parseConstraint width constraint $ \bits -> do
        bitSectionHibit nr hibit (map BM.bitAsQuasi bits)
    Nothing -> do
      bits <- fmap concat $ forChildren "c" box $ \c -> do
        let content = X.strContent c
        case X.findAttr (qname "colspan") c of
          Just colspan -> do
            unless (null content) $
              throwError $ InvalidChildElement
            return $ replicate (read colspan) (BM.bitAsQuasi $ BT.Any)
          Nothing | Just qbit <- BM.readQuasiBit content ->
           return [qbit]
          _ -> throwError $ InvalidChildElement
      unless (length bits == width) $
        throwError $ MismatchedWidth "getBoxField" width bits
      bitsect <- bitSectionHibit nr hibit bits
      return $ PropTree.clause $ bitsect
  name <- case X.findAttr (qname "name") box of
    Just name -> valOfNameExp <$> parseString nameExpParser name
    Nothing -> return ""
  return $ Field { fieldName = name
                 , fieldHibit = hibit
                 , fieldWidth = width
                 , fieldConstraint = constraint
                 , fieldUseName = X.findAttr (qname "usename") box == Just "1"
                 }

quasiMaskOfMask :: BitMask n BM.QuasiBit -> BitSection n ()
quasiMaskOfMask mask = BM.maskAsBitSection $ fmap getQuasi mask
  where
    getQuasi :: BM.QuasiBit -> BM.WithBottom ()
    getQuasi qbit = if BM.isQBit qbit then BM.JustBit () else BM.BottomBit

quasiMaskOfFields :: forall n . (1 <= n) => NR.NatRepr n -> [Field n] -> BitSection n ()
quasiMaskOfFields nr fields = foldr doMerge bs0 (catMaybes $ map getSection fields)
  where
    bs0 = BM.maskAsBitSection (BM.bottomBitMask nr)
    getSection :: Field n -> Maybe (BitSection n ())
    getSection (Field _name _hibit _width constraint useName)
      | (not useName) && any (any BM.isQBit) constraint
      = Just (BM.sectionOfConstraint nr constraint)
    getSection _ = Nothing

    doMerge :: BitSection n () -> BitSection n () -> BitSection n ()
    doMerge sect1 sect2 = fromMaybe (error "impossible") $ sect1 `BM.mergeBit` sect2

type Fields n = M.Map String (Field n)

lookupField' :: NR.NatRepr n -> Fields n -> String -> XML (Field n)
lookupField' nr flds name =
  case M.lookup name flds of
    Nothing -> throwError $ MissingField name nr flds
    Just fld -> return fld

lookupField :: NR.NatRepr n -> Fields n -> NameExp String -> XML (NameExp (Field n))
lookupField nr flds nme = mapM (lookupField' nr flds) nme

slicedFieldWidth :: NameExp (Field n) -> Int
slicedFieldWidth ne = case ne of
  NameExpString field -> fieldWidth field
  NameExpSlice _ hi lo -> hi - lo + 1

slicedFieldHibit :: NameExp (Field n) -> Int
slicedFieldHibit ne = case ne of
  NameExpString field -> fieldHibit field
  NameExpSlice field hi _ ->
    let
      lobit = (fieldHibit field - fieldWidth field) + 1
    in lobit + hi


valOfNameExp :: NameExp a -> a
valOfNameExp nexp = case nexp of
  NameExpString name -> name
  NameExpSlice name _ _ -> name

nameExps :: String -> XML [NameExp String]
nameExps ns = parseString nameExpsParser ns

nameExpsParser :: Parser [NameExp String]
nameExpsParser = P.sepBy1 nameExpParser (P.single ':')

nameExpParser :: Parser (NameExp String)
nameExpParser = do
    name   <- parseName
    slices <- P.many $ parseSlice
    case slices of
      [] -> return $ NameExpString name
      [(hi, lo)] -> return $ NameExpSlice name hi lo
      -- TODO: this is a workaround for a bug in the XML spec
      [(3, 1), (3, 1)] | name == "cond" -> return $ NameExpString name
      _ -> P.customFailure $ XMLInnerParserError $ "inconsistent slices: " ++ show slices

  where
    -- TODO: whitespace?
    parseSlice = do
        void $ P.single '<'
        hi <- parseInt
        (do
          void $ P.single ':'
          lo <- parseInt
          void $ P.single '>'
          pure (hi, lo)
          <|> do
          void $ P.single '>'
          pure (hi, hi))

    parseName = P.some (P.alphaNumChar P.<|> P.single '_')
    parseInt = read <$> P.some P.digitChar

data NameExp a =
    NameExpString a
  | NameExpSlice a Int Int
  deriving(Show, Functor, Foldable, Traversable)

-- | A description of an opcode field.
data Field n = Field { fieldName :: String
                   -- ^ the name of this field
                   , fieldHibit :: Int
                   -- ^ the index of the high bit (big-endian) of this field
                   , fieldWidth :: Int
                   -- ^ the number of bits for this field
                   , fieldConstraint :: PropTree (BitSection n QuasiBit)
                   -- ^ the bits of this field described as a 'PropTree'
                   , fieldUseName :: Bool
                   }
  deriving (Show, Eq)

-- | Perform any necessary byte swapping to interpret masks
--
-- The different instruction forms have different rules.  Thumb1 instructions
-- are (semantically) read as a Word16 where the two bytes need to be swapped.
-- ARM instructions are (semantically) read as a Word32 where the four bytes are
-- reversed. Thumb2 is the strange case, where they are read as two Word16s,
-- with independent byte swapping.
endianness :: EncodedForm -> [a] -> [a]
endianness efrm bits =
  case efrm of
    Thumb1Form -> byteswap bits
    Thumb2Form -> concatMap byteswap (List.chunksOf 16 bits)
    ARMForm -> byteswap bits
  where
    byteswap bs = concat (reverse (List.chunksOf 8 bs))

instance PP.Pretty Encoding where
  pPrint Encoding { encMask = mask, encNegMasks = negMasks, encOperands = operands, encName = name, encForm = efrm } =
    PP.text "Encoding:" <+> PP.text name
    $$ PP.text "Endian Swapped"
    $$ mkBody (endianness efrm)
    $$ PP.text "Original"
    $$ mkBody id
    $$ PP.text "Operands:"
    $$ PP.vcat (map PP.pPrint operands)
    where
      mkBody :: (forall a. [a] -> [a]) -> PP.Doc
      mkBody endianswap = PP.nest 1 $
           BM.prettySegmentedMask endianswap mask
           $$ PP.text "Negative Masks:"
           $$ PP.vcat (map (BM.prettySegmentedMask endianswap) negMasks)

instance PP.Pretty (Operand n) where
  pPrint (Operand name sect _isPsuedo) =
    PP.text name PP.<> PP.text ":" <+>
      BM.prettyBitSection (PP.text . BM.showBit) sect

parseString :: Show e => P.ShowErrorComponent e => P.Parsec e String a -> String -> XML a
parseString p txt = do
  currentFile <- (fromMaybe "") <$> R.asks xmlCurrentFile
  line <- (fromMaybe 1 . (listToMaybe >=> X.elLine)) <$> R.asks xmlCurrentPath
  case P.runParser p currentFile txt of
    Left err -> throwError $ InnerParserFailure $
      err { P.bundlePosState = setLine line (P.bundlePosState err) }
    Right a -> return a
  where
    setLine :: Integer -> P.PosState s -> P.PosState s
    setLine line ps =
      ps { P.pstateSourcePos  = (P.pstateSourcePos ps) { P.sourceLine = P.mkPos (fromIntegral line) } }

deriveMasks :: (1 <= n)
            => NR.NatRepr n
            -> PropTree (BitSection n QuasiBit)
            -> PropTree (BitSection n BT.Bit)
            -> XML (BitMask n QuasiBit, [BitMask n BT.Bit])
deriveMasks nr qbits bits = do
  let constraints = (fmap (fmap BM.bitAsQuasi) bits <> qbits)
  case BM.deriveMasks nr constraints of
    Left err -> throwError $ InvalidConstraints nr constraints err
    Right (posmask, negmasks) -> return (posmask, map (fmap BM.flattenQuasiBit) negmasks)

fieldConstraintsParser :: Parser (PropTree ([NameExp String], [BT.Bit]))
fieldConstraintsParser = do
  props <- outerParser
  P.eof
  return props
  where

    outerParser :: Parser (PropTree ([NameExp String], [BT.Bit]))
    outerParser = do
      mconcat <$> P.sepBy1 combinedParser ((void $ P.char ';') <|> (void $ P.chunk "&&"))

    combinedParser :: Parser (PropTree ([NameExp String], [BT.Bit]))
    combinedParser = do
      void $ P.takeWhileP Nothing (== ' ')
      props <- P.choice [ negParser
                        , P.between (P.char '(') (P.char ')') outerParser
                        , atomParser
                        ]
      void $ P.takeWhileP Nothing (== ' ')
      return props

    negParser :: Parser (PropTree ([NameExp String], [BT.Bit]))
    negParser = do
      void $ P.char '!'
      P.between (P.char '(') (P.char ')') (PropTree.negate <$> outerParser)

    atomParser :: Parser (PropTree ([NameExp String], [BT.Bit]))
    atomParser = do
      name <- nameExpsParser
      isnegated <- (P.chunk " == " >> return False) <|> (P.chunk " != " >> return True)
      bits <- P.some bitParser
      void $ P.takeWhileP Nothing (== ' ')
      if isnegated
        then return $ PropTree.negate $ PropTree.clause (name, bits)
        else return $ PropTree.clause (name, bits)

bitParser :: Parser BT.Bit
bitParser = do
  P.choice
    [ P.char '0' >> return (BT.ExpectedBit False)
    , P.char '1' >> return (BT.ExpectedBit True)
    , P.char 'x' >> return BT.Any
    ]

-- | A precursor to an 'DT.OperandDescriptor'.
data Operand n = Operand { opName :: String
                       -- ^ the name of this operand
                       , opSection :: BitSection n ()
                       -- ^ an 'ARMBitSection' specifying the opcode bits used for this field
                       , opIsPseudo :: Bool
                       -- ^ flag indicating that this is a "pseudo" operand, and not
                       -- actually used for any instruction semantics
                       }
  deriving Show

data EncodedForm = Thumb1Form
                 | Thumb2Form
                 | ARMForm
                 deriving (Eq, Ord, Show)

-- | An 'Encoding' represents an encoding from the ARM XML specification,
-- which includes a description of its fields.
data Encoding =
  forall n . (1 <= n) =>
  Encoding { encName :: String
                         -- ^ the unique name of this encoding (e.g. ADD_i_A1, ADDS_i_A1 )
                         , encMnemonic :: String
                         -- ^ the mnemonic of the instruction class that this encoding belongs to (e.g. aarch32_ADD_i_A )
                         -- shared between multiple encodings
                         , encConstraints :: PropTree (BitSection n BT.Bit)
                         -- ^ the bitfield constraints that identify this specific encoding
                         , encOperands :: [Operand n]
                         -- ^ the operands of this encoding
                         , encSize :: NR.NatRepr n
                         -- ^ The width of the encoding in bits
                         , encFields :: Fields n
                         -- ^ the named bitfields of the instruction
                         , encIConstraints :: PropTree (BitSection n QuasiBit)
                         -- ^ the constraints of this encoding that are common to all
                         -- the encodings of the instruction class it belongs to
                         , encMask :: BitMask n QuasiBit
                         -- ^ the complete positive mask of this encoding (derived from the constraints)
                         , encNegMasks :: [BitMask n BT.Bit]
                         -- ^ the complete negative masks of this encoding (derived from the constraints)
                         , encForm :: EncodedForm
                         -- ^ The instruction encoding (thumb1, thumb2, or arm),
                         -- which is used to help determine byte swapping as applied to the masks
                         }

deriving instance Show Encoding

bitSectionHibit :: IsMaskBit a => NR.NatRepr n -> Int -> [a] -> XML (BitSection n a)
bitSectionHibit nr hibit bits = case BM.bitSectionFromListHiBit hibit bits nr of
  Just bitsect -> return bitsect
  Nothing -> throwError $ InvalidBitsForBitsection nr hibit bits

unpackFieldConstraints :: forall a n . IsMaskBit a => NR.NatRepr n -> ([NameExp (Field n)], [a]) -> XML [BitSection n a]
unpackFieldConstraints nr (flds, bits) = do
  (rest, result) <- foldM go' (bits, []) flds
  case rest of
    [] -> return result
    _ -> throwError $ MismatchedFieldsForBits nr flds bits
  where
    go' :: ([a], [BitSection n a]) -> NameExp (Field n) -> XML ([a], [BitSection n a])
    go' (as, results) nme = do
      (as', result) <- go nme as
      return (as', result : results)

    go :: NameExp (Field n) -> [a] -> XML ([a], BitSection n a)
    go sField as = do
      let width = slicedFieldWidth sField
      let hibit = slicedFieldHibit sField
      let (bitchunk, rest) = splitAt width as
      unless (length bitchunk == width) $ do
        throwError $ MismatchedFieldsForBits nr flds bits
      bitsect <- bitSectionHibit nr hibit bitchunk
      return (rest, bitsect)

resolvePropTree :: forall a n
                 . IsMaskBit a
                => NR.NatRepr n
                -> Fields n
                -> PropTree ([NameExp String], [a])
                -> XML (PropTree (BitSection n a))
resolvePropTree nr fields tree =
  fmap PropTree.collapse $ mapM go tree
  where
    go :: ([NameExp String], [a]) -> XML [BitSection n a]
    go (nmes, as) = do
      fields' <- forM nmes $ lookupField nr fields
      unpackFieldConstraints nr (fields', as)


leafGetEncodingConstraints :: NR.NatRepr n
                           -> InstructionLeaf
                           -> Fields n
                           -> XML [(String, PropTree (BitSection n BT.Bit))]
leafGetEncodingConstraints nr ileaf fields = do
  let iclass = ileafiClass ileaf
  forChildren "encoding" iclass $ \encoding -> do
    name <- getAttr "name" encoding
    withEncodingName name $ do
      constraints <-  case X.findAttr (qname "bitdiffs") encoding of
        Nothing -> return mempty
        Just bitdiffs -> do
          parsedConstraints <- parseString fieldConstraintsParser bitdiffs
          resolvePropTree nr fields parsedConstraints
      return (name, constraints)

-- | Build operand descriptors out of the given fields
leafGetEncodings :: forall n
                  . (1 <= n)
                 => EncodedForm
                 -> InstructionLeaf
                 -> NR.NatRepr n
                 -> Fields n
                 -> BitSection n ()
                 -> PropTree (BitSection n QuasiBit)
                 -> XML [Encoding]
leafGetEncodings frm ileaf nrep allfields _quasimask iconstraints = do
  mnemonic <- leafMnemonic' ileaf
  encodingConstraints <- leafGetEncodingConstraints nrep ileaf allfields

  forM encodingConstraints $ \(encName', constraints) -> withEncodingName encName' $ do
      let immediates = map mkImmediateOp (M.elems allfields)
      (mask, negmasks) <- deriveMasks nrep iconstraints constraints

      let encoding = Encoding { encName = encName'
                              , encMnemonic = mnemonic
                              , encConstraints = constraints
                              , encOperands = immediates ++ (maybeToList $ psuedoOp mask)
                              , encFields = allfields
                              , encIConstraints = iconstraints
                              , encMask = mask
                              , encNegMasks = negmasks
                              , encSize = nrep
                              , encForm = frm
                              }

      MS.modify' $ \st -> st { encodingMap = M.insert encName' encoding (encodingMap st) }
      return encoding
  where
    psuedoOp :: BitMask n BM.QuasiBit -> Maybe (Operand n)
    psuedoOp mask =
      let
        qmask = quasiMaskOfMask mask
        totalWidth = BM.sectTotalSetWidth qmask
      in if totalWidth > 0
      then Just $ Operand "QuasiMask" qmask True
      else Nothing


    mkImmediateOp :: Field n -> Operand n
    mkImmediateOp (Field name _ _ constraint _) =
      let
        sect = BM.sectionOfConstraint nrep constraint
      in Operand name sect False

findiClassByName :: X.Element -> String -> XML X.Element
findiClassByName e name = do
  classes <- getChild "classes" e
  iclasses <- fmap catMaybes $ forChildren "iclass" classes $ \iclass -> do
    case X.findAttr (qname "name") iclass of
      Just name' | name' == name -> return $ Just iclass
      _ -> return Nothing
  case iclasses of
    [iclass] -> return iclass
    _ -> throwError $ NoUniqueiClass name


findXMLFile :: String -> XML FilePath
findXMLFile fileName = do
  allfiles <- R.asks xmlAllFiles
  case List.find (\f -> takeFileName f == fileName) allfiles of
    Just fn -> return fn
    Nothing -> throwError $ MissingXMLFile fileName

isAliasedInstruction :: InstructionLeaf -> Bool
isAliasedInstruction ileaf = isJust $ X.findChild (qname "aliasto") (ileafFull ileaf)

leafMnemonic' :: InstructionLeaf -> XML String
leafMnemonic' ileaf = do
  regdiagram <- getChild "regdiagram" iclass
  psname <- getAttr "psname" regdiagram
  case psname of
    "" -> lookupAlias
    _ -> parseString nameParser psname
  where
    iclass = ileafiClass ileaf

    lookupAlias :: XML String
    lookupAlias = do
      alias <- getChild "aliasto" (ileafFull ileaf)
      iclassname <- getAttr "name" iclass
      aliasedXMLFile <- getAttr "refiform" alias >>= findXMLFile
      withParsedXMLFile aliasedXMLFile $ \aliasedXML -> do
        aliasediclass <- findiClassByName aliasedXML iclassname
        leafMnemonic' (InstructionLeaf aliasedXML aliasediclass)


instDescriptorsToISA :: [DT.InstructionDescriptor] -> DT.ISADescriptor
instDescriptorsToISA instrs =
  DT.ISADescriptor { DT.isaInstructions = instrs
                   , DT.isaOperands = S.toList (S.fromList (concatMap instrOperandTypes instrs))
                   , DT.isaErrors = []
                   }

instrOperandTypes :: DT.InstructionDescriptor -> [DT.OperandType]
instrOperandTypes idesc = map DT.opType (DT.idInputOperands idesc ++ DT.idOutputOperands idesc)

sectionToChunks :: NR.NatRepr n -> BitSection n a -> [(DT.IBit, PT.OBit, Word8)]
sectionToChunks nr sect =
  map getChunk (BM.asContiguousSections sect)
  where
    -- BitSection positions are indexed from the start of the bitmask vector, which is
    -- the most significant bit for ARM (i.e. a big-endian index).
    -- Dismantle wants the little-endian index of the least significant bit of the operand.
    getChunk :: (Int, BM.SomeBitMask a) -> (DT.IBit, PT.OBit, Word8)
    getChunk (pos, BM.SomeBitMask mask) =
      let
        width = BM.lengthInt mask
        regwidth = fromIntegral $ NR.intValue nr
        hibit = regwidth - pos - 1
        ibitpos = hibit - width + 1
      in (DT.IBit ibitpos, PT.OBit 0, fromIntegral width)

-- | Mapping field names used in the XML specification to corresponding names
-- in the ASL specification.
xmlFieldNameToASL :: String -> String
xmlFieldNameToASL name = case name of
  "type" -> "type1"
  _ -> name

operandToDescriptor :: NR.NatRepr n -> Operand n -> [DT.OperandDescriptor]
operandToDescriptor nr (Operand name sect isPseudo) = case isPseudo of
  False -> [DT.OperandDescriptor { DT.opName = xmlFieldNameToASL $ name
                                 , DT.opChunks = sectionToChunks nr sect
                                 , DT.opType = DT.OperandType $ printf "Bv%d" totalWidth
                                 }]
  True -> map mkPseudo $ zip [0..] (sectionToChunks nr sect)
  where
    totalWidth = BM.sectTotalSetWidth sect

    mkPseudo :: (Int, (DT.IBit, PT.OBit, Word8)) -> DT.OperandDescriptor
    mkPseudo (i, chunk@(_, _, width)) =
      DT.OperandDescriptor { DT.opName = printf "QuasiMask%d" i
                           , DT.opChunks = [chunk]
                           , DT.opType = DT.OperandType $ printf "QuasiMask%d" width
                           }


-- | As 'operandToDescriptor' but creates a single, disjointed pseudo-operand instead of multiple.
-- Currently using this will break instruction re-assembly for reasons that are not understood.
_operandToDescriptor' :: NR.NatRepr n -> Operand n -> [DT.OperandDescriptor]
_operandToDescriptor' nr (Operand name sect isPseudo) =
  [DT.OperandDescriptor { DT.opName = name
                        , DT.opChunks = sectionToChunks nr sect
                        , DT.opType = DT.OperandType $ printf opTypeFormat totalWidth
                        }]
  where
    totalWidth = BM.sectTotalSetWidth sect

    opTypeFormat :: String
    opTypeFormat = if isPseudo then "QuasiMask%d" else "Bv%d"

-- | Return the list of real operands and pseudo operands for a given encoding.
getOperandDescriptors :: Encoding -> ([DT.OperandDescriptor], [DT.OperandDescriptor])
getOperandDescriptors Encoding { encOperands = operands, encSize = nr } =
  let
    (pseudo, real) = List.partition opIsPseudo operands
  in (concat $ map (operandToDescriptor nr) real, concat $ map (operandToDescriptor nr) pseudo)

encodingOpToInstDescriptor :: Encoding -> DT.InstructionDescriptor
encodingOpToInstDescriptor encoding@Encoding { encMnemonic = mnemonic
                                             , encName = name
                                             , encNegMasks = negMasks
                                             , encMask = mask
                                             , encForm = efrm
                                             } =
  let
    (realops, pseudoops) = getOperandDescriptors encoding
  in DT.InstructionDescriptor
       { DT.idMask = map BM.flattenQuasiBit (endianness efrm $ BM.toList mask)
       , DT.idNegMasks = map (endianness efrm . BM.toList) negMasks
       , DT.idMnemonic = name
       , DT.idInputOperands = realops ++ pseudoops
       , DT.idOutputOperands = []
       , DT.idNamespace = mnemonic
       , DT.idDecoderNamespace = ""
       , DT.idAsmString = name
         ++ "(" ++ PP.render (BM.prettySegmentedMask (endianness efrm) mask) ++ ") "
         ++ simpleOperandFormat (realops ++ pseudoops)
       , DT.idPseudo = False
       , DT.idDefaultPrettyVariableValues = []
       , DT.idPrettyVariableOverrides = []
       }

simpleOperandFormat :: [DT.OperandDescriptor] -> String
simpleOperandFormat descs = List.intercalate ", " $ map go descs
  where
    go :: DT.OperandDescriptor -> String
    go oper = DT.opName oper ++ " ${" ++ DT.opName oper ++ "}"

forChildren :: String -> X.Element -> (X.Element -> XML a) -> XML [a]
forChildren name elt m = mapM (\e -> withElement e $ m e) $ X.filterChildrenName ((==) $ qname name) elt

data XMLInnerParserError = XMLInnerParserError String
  deriving (Show, Eq, Ord)

instance P.ShowErrorComponent XMLInnerParserError where
  showErrorComponent e = case e of
    XMLInnerParserError msg -> msg

type Parser = P.Parsec XMLInnerParserError String

nameParser :: Parser String
nameParser = do
  _ <- P.chunk "aarch32/instrs/"
  instrName <- P.takeWhileP Nothing (/= '/')
  _ <- P.chunk "/"
  xencName <- P.takeWhileP Nothing (/= '.')
  _ <- P.chunk ".txt"
  return $ instrName <> "_" <> xencName

getChild :: String -> X.Element -> XML X.Element
getChild name elt = case X.findChild (qname name) elt of
  Nothing -> withElement elt $ throwError $ MissingChildElement name
  Just child -> return child

withChild :: String -> X.Element -> (Maybe X.Element -> XML a) -> XML a
withChild name elt m = do
  case X.findChild (qname name) elt of
    Just elt' -> withElement elt' $ m (Just elt')
    Nothing -> m Nothing


getAttr :: String -> X.Element -> XML String
getAttr name elt = case X.findAttr (qname name) elt of
  Nothing -> withElement elt $ throwError $ MissingAttr name
  Just attr -> return attr

getAttrs :: [String] -> X.Element -> XML [String]
getAttrs names elt = mapM (\name -> getAttr name elt) names

resolvePath :: X.Element -> [(String, Maybe (String, String))] -> XML [X.Element]
resolvePath elt path = withElement elt $ case path of
  (p : ps) -> do
    fmap concat $ forM (go p elt) $ \elt' ->
      resolvePath elt' ps
  _ -> return [elt]
  where
    go :: (String, Maybe (String, String)) -> X.Element -> [X.Element]
    go p e = X.filterChildren (getfilter p) e

    getfilter :: (String, Maybe (String, String)) -> X.Element -> Bool
    getfilter (nm, Nothing) e = X.qName (X.elName e) == nm
    getfilter (nm, Just (attrnm, attrval)) e =
      X.qName (X.elName e) == nm && X.findAttr (qname attrnm) e == Just attrval
