module Emulator.PPU (
    reset
  , step
) where

import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Bits              (shiftL, shiftR, (.&.), (.|.))
import           Data.IORef
import qualified Data.Vector            as V
import           Data.Word
import           Emulator.Monad
import           Emulator.Nes
import           Emulator.Util
import           Prelude                hiding (cycle)

data PreRenderPhase
  = PreRenderReloadY
  | PreRenderClearVBlank
  | PreRenderIdle
  deriving (Eq, Show)

data RenderPhase
  = RenderVisible
  | RenderPreFetch
  | RenderIdle
  deriving (Eq, Show)

data FramePhase
  = PreRender PreRenderPhase
  | Render RenderPhase
  | PostRender
  | VBlank
  deriving (Eq, Show)

reset :: IOEmulator ()
reset = do
  store (Ppu PpuCycles) 340
  store (Ppu Scanline) 240
  store (Ppu VerticalBlank) False

step :: IOEmulator ()
step = do
  (scanline, cycle) <- tick

  let framePhase = getFramePhase scanline cycle

  case framePhase of
    PreRender phase -> handlePreRenderPhase phase
    Render phase    -> handleRenderPhase phase scanline cycle
    PostRender      -> idle
    VBlank          -> enterVBlank

tick :: IOEmulator (Int, Int)
tick = do
  modify (Ppu PpuCycles) (+1)
  cycles <- load $ Ppu PpuCycles

  when (cycles > 340) $ do
    store (Ppu PpuCycles) 0
    modify (Ppu Scanline) (+1)
    scanline <- load (Ppu Scanline)

    when (scanline > 261) $ do
      store (Ppu Scanline) 0
      modify (Ppu FrameCount) (+1)

  scanline <- load $ Ppu Scanline
  cycles <- load $ Ppu PpuCycles

  pure (scanline, cycles)

getRenderPhase :: Int -> RenderPhase
getRenderPhase cycle
  | cycle == 0 = RenderIdle
  | cycle >= 1 && cycle <= 256 = RenderVisible
  | cycle >= 321 && cycle <= 336 = RenderPreFetch
  | otherwise = RenderIdle

getPreRenderPhase :: Int -> PreRenderPhase
getPreRenderPhase cycle
  | cycle == 1 = PreRenderClearVBlank
  | cycle >= 280 && cycle <= 304 = PreRenderReloadY
  | otherwise = PreRenderIdle

getFramePhase :: Int -> Int -> FramePhase
getFramePhase scanline cycle
  | scanline >= 0 && scanline <= 239 = Render $ getRenderPhase cycle
  | scanline == 240 = PostRender
  | scanline >= 241 && scanline <= 260 = VBlank
  | scanline == 261 = PreRender $ getPreRenderPhase cycle
  | otherwise = error $ "Erronenous frame phase detected at scanline "
    ++ show scanline ++ " and cycle "
    ++ show cycle

handlePreRenderPhase :: PreRenderPhase -> IOEmulator ()
handlePreRenderPhase phase = idle

handleRenderPhase :: RenderPhase -> Int -> Int -> IOEmulator ()
handleRenderPhase phase scanline cycle = case phase of
  RenderVisible -> renderPixel scanline cycle
  other         -> idle

renderPixel :: Int -> Int -> IOEmulator ()
renderPixel scanline cycle = do
  scrollX <- load $ Ppu ScrollX
  scrollY <- load $ Ppu ScrollY

  let x = cycle - 1
  let y' = scanline + fromIntegral scrollY

  -- let y' = if y >= 240 then y - 240 else y



  ntAddr <- nametableAddr (x `div` 8, y' `div` 8)

  -- trace (show ntAddr)

  tile <- loadTile ntAddr
  patternPixel <- getPatternPixel (fromIntegral tile) (x `mod` 8, y' `mod` 8)

  paletteIndex <- load $ Ppu $ PpuMemory8 (0x3F00 + fromIntegral patternPixel)
  let paletteIndex' = paletteIndex .&. 0x3f
  let paletteColor = getColor paletteIndex'

  store (Ppu $ Screen (x, y')) paletteColor


idle :: IOEmulator ()
idle = pure ()

enterVBlank :: IOEmulator ()
enterVBlank = do
  store (Ppu VerticalBlank) True
  generateNMI <- load (Ppu GenerateNMI)
  when generateNMI $ store (Cpu Interrupt) (Just NMI)

exitVBlank :: IOEmulator ()
exitVBlank = store (Ppu VerticalBlank) False

data NameTableAddress = NameTableAddress {
  xIndex :: Word8,
  yIndex :: Word8,
  base   :: Word16
} deriving (Show, Eq)

nametableAddr :: (Int, Int) -> IOEmulator NameTableAddress
nametableAddr (x, y) = do
  base <- load $ Ppu NameTableAddr
  pure $ NameTableAddress (fromIntegral $ xIndex `mod` 32) (fromIntegral $ yIndex `mod` 30) base
  where
    xIndex = x `mod` 64
    yIndex = y `mod` 60
    -- base = case (xIndex >= 32, yIndex >= 30) of
    --   (False, False) -> 0x2000
    --   (True, False)  -> 0x2400
    --   (False, True)  -> 0x2800
    --   (True, True)   -> 0x2c00


loadTile :: NameTableAddress -> IOEmulator Word8
loadTile (NameTableAddress x y base) = load (Ppu $ PpuMemory8 addr)
  where addr = base + 32 * fromIntegral y + fromIntegral x

getPatternPixel :: Word16 -> (Int, Int) -> IOEmulator Word8
getPatternPixel tile (x, y) = do
  bgTableAddr <- load $ Ppu BackgroundTableAddr
  let offset = (tile `shiftL` 4) + fromIntegral y + bgTableAddr

  pattern0 <- load $ Ppu $ PpuMemory8 offset
  pattern1 <- load $ Ppu $ PpuMemory8 $ offset + 8
  let bit0 = (pattern0 `shiftR` (7 - (fromIntegral x `mod` 8))) .&. 1
  let bit1 = (pattern1 `shiftR` (7 - (fromIntegral x `mod` 8))) .&. 1

  pure $ (bit1 `shiftL` 1) .|. bit0

getColor :: Word8 -> (Word8, Word8, Word8)
getColor paletteIndex = palette V.! (fromIntegral paletteIndex)

palette :: V.Vector (Word8, Word8, Word8)
palette = V.fromList
  [ (0x66, 0x66, 0x66), (0x00, 0x2A, 0x88),
    (0x14, 0x12, 0xA7), (0x3B, 0x00, 0xA4),
    (0x5C, 0x00, 0x7E), (0x6E, 0x00, 0x40),
    (0x6C, 0x06, 0x00), (0x56, 0x1D, 0x00),
    (0x33, 0x35, 0x00), (0x0B, 0x48, 0x00),
    (0x00, 0x52, 0x00), (0x00, 0x4F, 0x08),
    (0x00, 0x40, 0x4D), (0x00, 0x00, 0x00),
    (0x00, 0x00, 0x00), (0x00, 0x00, 0x00),
    (0xAD, 0xAD, 0xAD), (0x15, 0x5F, 0xD9),
    (0x42, 0x40, 0xFF), (0x75, 0x27, 0xFE),
    (0xA0, 0x1A, 0xCC), (0xB7, 0x1E, 0x7B),
    (0xB5, 0x31, 0x20), (0x99, 0x4E, 0x00),
    (0x6B, 0x6D, 0x00), (0x38, 0x87, 0x00),
    (0x0C, 0x93, 0x00), (0x00, 0x8F, 0x32),
    (0x00, 0x7C, 0x8D), (0x00, 0x00, 0x00),
    (0x00, 0x00, 0x00), (0x00, 0x00, 0x00),
    (0xFF, 0xFE, 0xFF), (0x64, 0xB0, 0xFF),
    (0x92, 0x90, 0xFF), (0xC6, 0x76, 0xFF),
    (0xF3, 0x6A, 0xFF), (0xFE, 0x6E, 0xCC),
    (0xFE, 0x81, 0x70), (0xEA, 0x9E, 0x22),
    (0xBC, 0xBE, 0x00), (0x88, 0xD8, 0x00),
    (0x5C, 0xE4, 0x30), (0x45, 0xE0, 0x82),
    (0x48, 0xCD, 0xDE), (0x4F, 0x4F, 0x4F),
    (0x00, 0x00, 0x00), (0x00, 0x00, 0x00),
    (0xFF, 0xFE, 0xFF), (0xC0, 0xDF, 0xFF),
    (0xD3, 0xD2, 0xFF), (0xE8, 0xC8, 0xFF),
    (0xFB, 0xC2, 0xFF), (0xFE, 0xC4, 0xEA),
    (0xFE, 0xCC, 0xC5), (0xF7, 0xD8, 0xA5),
    (0xE4, 0xE5, 0x94), (0xCF, 0xEF, 0x96),
    (0xBD, 0xF4, 0xAB), (0xB3, 0xF3, 0xCC),
    (0xB5, 0xEB, 0xF2), (0xB8, 0xB8, 0xB8),
    (0x00, 0x00, 0x00), (0x00, 0x00, 0x00) ]
