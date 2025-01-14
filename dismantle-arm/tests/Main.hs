{-# LANGUAGE OverloadedStrings #-}

{-
  Note: when a binary representation of an ARM instruction is
        displayed, the byte order is: 6 7 4 5 2 3 0 1

        In the documentation, bits 31 .... 0  correspond to bytes 0 ... 7

  For example:

    10001100.00110000.10010011.11100001      orrs r3, r3, ip, lsl #1
    ----____ ----____ ----____ ----____
      6   7    4   5    2   3    0   1

    [defined on page F7.1.127, F7-2738]

    Translation:
     cond 0011 100S .rn. .rd. ..imm12....
        rn = r3
        rd = r3
        lsl = 0b00
        imm12 = 0000 1000 1100  = 0x08c
-}

module Main ( main ) where

import           Data.Char (isSpace)
import qualified Data.List as L
import           Data.Monoid ((<>))
import qualified Data.Text.Lazy as TL
import           Data.Word (Word64)
import qualified Test.Tasty as T
import qualified Text.PrettyPrint.HughesPJClass as PP

import qualified Dismantle.ARM as ARM
import qualified Dismantle.ARM.ISA as ARM
import           Dismantle.Testing
import           Dismantle.Testing.ParserTests ( parserTests )
import qualified Dismantle.Testing.Regex as RE

import MiscARMTests ( miscArmTests )


ignored :: [(FilePath, [Word64])]
ignored =
    [ ("tests/bin/ls"
      , [ 0x1e198
        -- This address is ignored because objdump considers this byte
        -- sequence to be a 'tst' instruction, but that is incorrect.
        -- The ARM ARM specifies this as an MRS instruction. We parse it
        -- correctly.
        -- 1e198:       01010101        tsteq   r1, r1, lsl #2
        ]
      )
    , ("tests/bin/libfftw3.so.3.4.4"
      , [
        -- These addresses are ignored because objdump considers them to
        -- be 'cmn' instructions but that is clearly wrong in the ARM
        -- ARM.
          0x9a948
        , 0xea750
        , 0x131780
        , 0x181300

        -- These addresses all use the same non-instruction byte
        -- sequence: 0x3c182b51. objdump claims this disassembles to
        -- ldccc, but none of the ARM ARM patterns for LDC match this
        -- sequence.
        , 0x36408
        , 0x372e8
        , 0x37718
        , 0x37b48
        , 0x5a498
        , 0x5a4e8
        , 0x5b220
        , 0x5b698
        , 0x7b520
        , 0x7b570
        , 0x7c298
        , 0x7c728
        , 0xb07f0
        , 0xb0c38
        , 0xb0cb8
        , 0xb1978
        , 0xb19c0
        , 0xd41d0
        , 0xd4690
        , 0xd5820
        , 0xe6cb8
        , 0xe7180
        , 0xe82f8
        , 0xf5ee0
        , 0xf6358
        , 0xf63a0
        , 0xf6f78
        , 0xf6fa8
        , 0x1488d0
        , 0x148d20
        , 0x168d40
        , 0x169df8
        , 0x17ba78
        , 0x17ca88
        , 0x18cab8
        , 0x18cec8

        -- These addresses are considered 'sbc' instructions by objdump,
        -- but we disassemble them as 'adrpc' legally.
        , 0x1b7d8
        , 0x3c9f0
        , 0x9a928
        , 0xb7098
        , 0xea738
        , 0x1319e8
        , 0x14d0f0
        , 0x181308

        -- These addresses are considered to be 'and' instructions by
        -- objdump, but we disassemble them as 'adr'. objdump is wrong.
        , 0x20270
        , 0x20720
        , 0x20748
        , 0x20fa0
        , 0x9d298
        , 0x9d2a0
        , 0x133ea8
        , 0x133ee8

        -- Objdump claims "strdvc" but the Tgen says otherwise for that
        -- instruction.
        , 0x9a930
        , 0xea740
        , 0x131778
        , 0x1812f8

        -- This location is handled properly by our library, but our
        -- pretty-print for it is nicer than objdump.
        , 0xb0ec
        ]
      )
    ]

arm :: ArchTestConfig
arm = ATC { testingISA = ARM.isa
          , disassemble = ARM.disassembleInstruction
          , assemble = ARM.assembleInstruction
          , prettyPrint = ARM.ppInstruction
          , expectFailure = Just expectedFailures
          , skipPrettyCheck = Just skipPretty
          , ignoreAddresses = ignored
          , customObjdumpArgs = []
          , normalizePretty = normalize
          , comparePretty = Just cmpInstrs
          , instructionFilter = ((== FullWord) . insnLayout)
          }

main :: IO ()
main = do
  tg <- binaryTestSuite arm "tests/bin"
  pt <- parserTests
  mt <- miscArmTests
  T.defaultMain $ T.testGroup "dismantle-arm" [tg, pt, mt]

normalize :: TL.Text -> TL.Text
normalize =
    -- Then remove whitespace
    TL.filter (not . isSpace) .
    -- Remove square brackets and "#"
    TL.filter (flip notElem ("[]#"::String)) .
    -- First, trim any trailing comments
    (fst . TL.breakOn ";")

cmpInstrs :: TL.Text -> TL.Text -> Bool
cmpInstrs objdump dismantle =
  -- Many operations have an optional shift amount that does not need
  -- to be specified when the shift amount is zero.  Some objdump
  -- output contains this value however, but dismantle doesn't, so if
  -- a direct comparison fails, try stripping a ", 0" from the objdump
  -- version and check equality of that result (n.b. comparing the
  -- normalized versions, spaces are stripped).
  objdump == dismantle ||
  (",0" `TL.isSuffixOf` objdump &&
    (TL.reverse $ TL.drop 2 $ TL.reverse objdump) == dismantle)

rx :: String -> RE.Regex
rx s =
  case RE.mkRegex s of
    Left e -> error ("Invalid regex <<" ++ s ++ ">> because: " ++ e)
    Right r -> r

skipPretty :: RE.Regex
skipPretty = rx (L.intercalate "|" rxes)
  where
    rxes = others <> (matchInstruction <$> skipped)

    others = [
             -- We need to ignore these instructions when they mention
             -- the PC since objdump disassembles those as "add" etc.
             -- but we disassemble them as the (admittedly nicer) "adr".
               "add[[:space:]]..,[[:space:]]pc"
             , "sub[[:space:]]..,[[:space:]]pc"

             -- Any objdump output line with the word "illegal"
             -- (usually "illegal reg") is definitely a line we should
             -- ignore. It's probably a data byte sequence being
             -- parsed as an instruction.
             , "illegal"
             ]

    skipped = [
              -- We ignore branching instructions because objdump
              -- resolves the branch targets and we can't, so we can
              -- never match objdump's output.
                "bls"
              , "bl"
              , "b"

              -- These get represented as load/store multiple with sp
              -- mutation; push and pop are not even mentioned in the
              -- Tgen data.
              , "push"
              , "pop"

              -- Objdump knows about these but Tgen doesn't.
              , "cfldr64"
              , "cfldr32"
              , "cfstrs"

              -- These instructions are ones that the ISA specifically
              -- ignores right now.
              , "fldmdbx"
              , "vstr"

              -- These are equivalent to MOV but we don't format
              -- them that way. (See the ARM ARM, A8.8.105 MOV
              -- (shifted register), table: MOV (shifted register)
              -- equivalences). These are canonical forms, but they're
              -- marked as pseudo-instructions in the Tgen and we use
              -- the MOV representation while objdump uses the ones
              -- below.
              , "asrs?"
              , "lsls?"
              , "lsrs?"
              , "rors?"
              , "rrxs?"

              -- Ignored because the Tgen format string uses "stm" for
              -- this instruction and objdump uses "stmia".
              , "stmia"

              -- Ignored because the Tgen pretty-print format string has
              -- mistakes.
              , "pkhtb"

              -- Ignored because the Tgen format string uses "ldm" for
              -- this instruction and objdump uses "ldmfd".
              , "ldmfd"

              -- Ignored because the Tgen format string for these
              -- reference an implied operand that isn't mentioned
              -- in the bit patterns, so it's impossible for us to
              -- pretty-print these.
              , "ldrdeq"
              , "strdeq"
              , "mrc"
              , "mcr2"
              , "mrc2"
              , "strd"
              , "strb"
              , "ldrd"

              -- Ignored because we don't have enough context to format
              -- the arguments correctly.
              , "stcl"
              , "ldrsht"
              , "ldcl"
              , "mcr"
              , "blx"
              , "cdp"
              , "stc"
              , "stc2l"

              -- Ignored because I don't think we have enough control over
              -- format strings to print the special purpose registers correctly
              , "mrs"
              , "msr"

              -- We show nop as "mov r0, r0"
              , "nop"
              ]

    matchInstruction name = "(^[[:space:]]*" <> name <> conditions <> "[[:space:]])"

    conditions = "(" <> (concat $ L.intersperse "|"
                  (PP.render <$> PP.pPrint <$> ARM.mkPred <$> [0..13])) <> ")?"

expectedFailures :: RE.Regex
expectedFailures = rx (L.intercalate "|" rxes)
  where
    rxes = [ -- The tablegen data for MVN is currently incorrect
             -- w.r.t. unpredictable bits. The only variant of
             -- MVN that we've encountered that actually sets
             -- some unpredictable bits is 'mvnpl'. A bug has been
             -- submitted upstream. In the mean time, for details, see
             -- https://bugs.llvm.org/show_bug.cgi?id=33011
             "^[[:space:]]*mvnpl"
           ]
