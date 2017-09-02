module Emulator (
  -- * Functions
    run
  , r
) where

import           Cartridge
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Bits              (clearBit, setBit, testBit, (.&.),
                                         (.|.))
import           Data.ByteString        as BS hiding (putStrLn, replicate, take,
                                               zip)
import           Data.Word
import           Log
import           Monad
import           Nes                    (Address (..), Flag (..))
import           Opcode
import           Util

data EmulatorState
  = Continue
  | Fail
  deriving (Eq)

r :: IO ()
r = void $ runDebug "roms/nestest.nes" 0xC000 (pure Continue)

run :: FilePath -> IO ()
run fp = do
  cart <- parseCartridge <$> BS.readFile fp
  runIOEmulator cart $ do
    store Pc 0xC000
    void $ emulate $ pure Continue

runDebug :: FilePath -> Word16 -> Monad.IOEmulator EmulatorState -> IO EmulatorState
runDebug fp start hook = do
  cart <- parseCartridge <$> BS.readFile fp
  runIOEmulator cart $ do
    store Pc start
    emulate hook

loadNextOpcode :: (MonadIO m, MonadEmulator m) => m Opcode
loadNextOpcode = do
  pc <- load Pc
  pcv <- load (Ram8 pc)
  pure $ decodeOpcode pcv

emulate :: (MonadIO m, MonadEmulator m) => m EmulatorState -> m EmulatorState
emulate hook = do
  opcode <- loadNextOpcode
  execute opcode
  hookRes <- hook
  case hookRes of
    Continue -> emulate hook
    Fail     -> pure Fail

incrementPc :: MonadEmulator m => Word16 -> m ()
incrementPc n = do
  pc <- load Pc
  store Pc (pc + n)

addressForMode :: (MonadIO m, MonadEmulator m) => AddressMode -> m Word16
addressForMode mode = case mode of
  Absolute -> do
    pcv <- load Pc
    load $ Ram16 (pcv + 1)
  Immediate -> do
    pcv <- load Pc
    pure $ pcv + 1
  Implied ->
    pure $ toWord16 0
  Relative -> do
    pcv <- load Pc
    offset16 <- load $ Ram16 (pcv + 1)
    let offset8 = firstNibble offset16
    if offset8 < 0x80 then
      pure $ pcv + 2 + offset8
    else
      pure $ pcv + 2 + offset8 - 0x100
  ZeroPage -> do
    pcv <- load Pc
    v <- load $ Ram8 (pcv + 1)
    pure $ toWord16 v
  other -> error $ "Unimplemented AddressMode " ++ (show other)

pcIncrementForOpcode :: Opcode -> Word16
pcIncrementForOpcode (Opcode _ mn mode) = case (mode, mn) of
  (_, JMP)             -> 0
  (_, JSR)             -> 0
  (_, RTS)             -> 0
  (_, RTI)             -> 0
  (Indirect, _)        -> 0
  (Relative, _)        -> 2
  (Accumulator, _)     -> 1
  (Implied, _)         -> 1
  (Immediate, _)       -> 2
  (IndexedIndirect, _) -> 2
  (IndirectIndexed, _) -> 2
  (ZeroPage, _)        -> 2
  (ZeroPageX, _)       -> 2
  (ZeroPageY, _)       -> 2
  (Absolute, _)        -> 3
  (AbsoluteX, _)       -> 3
  (AbsoluteY, _)       -> 3

execute :: (MonadIO m, MonadEmulator m) => Opcode -> m ()
execute op @ (Opcode _ mn mode) = do
  pcv <- load Pc
  spv <- load Sp
  liftIO $ putStrLn $ "PC: " ++ (prettifyWord16 pcv) ++ " " ++ (show op) ++ " SP: " ++ (prettifyWord8 spv)
  addr <- addressForMode mode
  incrementPc $ pcIncrementForOpcode op
  go addr
  where
    go = case mn of
      BCC     -> bcc
      BCS     -> bcs
      BEQ     -> beq
      BIT     -> bit
      BNE     -> bne
      CLC     -> const clc
      JMP     -> jmp
      JSR     -> jsr
      LDA     -> lda
      LDX     -> ldx
      NOP     -> const nop
      SEC     -> const sec
      STA     -> sta
      STX     -> stx
      STY     -> sty
      unknown -> error $ "Unimplemented opcode: " ++ (show unknown)

push :: MonadEmulator m => Word8 -> m ()
push v = do
  spv <- load Sp
  store (Ram8 $ 0x100 .|. (toWord16 spv)) v
  store Sp (spv - 1)

push16 :: MonadEmulator m => Word16 -> m ()
push16 v = do
  let (lo, hi) = splitW16 v
  push hi
  push lo

-- BCC - Branch on carry flag clear
bcc :: MonadEmulator m => Word16 -> m ()
bcc = branch $ not <$> getFlag FC

-- BCS - Branch on carry flag set
bcs :: MonadEmulator m => Word16 -> m ()
bcs = branch $ getFlag FC

-- BEQ - Branch if zero set
beq :: MonadEmulator m => Word16 -> m ()
beq = branch $ getFlag FZ

-- BIT -
bit :: MonadEmulator m => Word16 -> m ()
bit addr = undefined
  -- do
  -- v <- load $ Ram8 addr
  -- store $ (P FV) ((v `shiftR` 6) .&. 1)

-- BNE - Branch if zero not set
bne :: MonadEmulator m => Word16 -> m ()
bne = branch $ not <$> getFlag FZ

-- CLC - Clear carry flag
clc :: MonadEmulator m => m ()
clc = setFlag FC False

-- JMP - Move execution to a particular address
jmp :: MonadEmulator m => Word16 -> m ()
jmp = store Pc

-- JSR - Jump to subroutine
jsr :: MonadEmulator m => Word16 -> m ()
jsr addr = do
  pcv <- load Pc
  push16 $ pcv - 1
  store Pc addr

-- LDA - Load accumulator register
lda :: MonadEmulator m => Word16 -> m ()
lda addr = do
  v <- load $ Ram8 addr
  store A v
  setZN v

-- LDX - Load X Register
ldx :: MonadEmulator m => Word16 -> m ()
ldx addr = do
  v <- load $ Ram8 addr
  store X v
  setZN v

-- NOP - No operation. Do nothing :D
nop :: MonadEmulator m => m ()
nop = pure ()

-- SEC - Set carry flag
sec :: MonadEmulator m => m ()
sec = setFlag FC True

-- STA - Store Accumulator register
sta :: MonadEmulator m => Word16 -> m ()
sta addr = (load A) >>= (store $ Ram8 addr)

-- STX - Store X register
stx :: MonadEmulator m => Word16 -> m ()
stx addr = (load X) >>= (store $ Ram8 addr)

-- STY - Store Y register
sty :: MonadEmulator m => Word16 -> m ()
sty addr = (load Y) >>= (store $ Ram8 addr)

-- Moves execution to addr if condition is set
branch :: MonadEmulator m => (m Bool) -> Word16 -> m ()
branch cond addr = do
  c <- cond
  if c then
    store Pc addr
  else
    pure ()


getFlag :: MonadEmulator m => Flag -> m Bool
getFlag flag = do
  v <- load P
  pure $ testBit v (7 - fromEnum flag)

setFlag :: MonadEmulator m => Flag -> Bool -> m ()
setFlag flag b = do
  v <- load P
  store P (opBit v (7 - fromEnum flag))
  where opBit = if b then setBit else clearBit

-- Sets the zero flag
setZ :: MonadEmulator m => Word8 -> m ()
setZ v = setFlag FZ (v == 0)

-- Sets the negative flag
setN :: MonadEmulator m => Word8 -> m ()
setN v = setFlag FN (v .&. 0x80 /= 0)

-- Sets the zero flag and the negative flag
setZN :: MonadEmulator m => Word8 -> m ()
setZN v = setZ v >> setN v

trace :: (MonadIO m, MonadEmulator m) => String -> m ()
trace v = liftIO $ putStrLn v
