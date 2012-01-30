{-
    Zachary Weaver <zaw6@pitt.edu>
    Version 0.1.1
    Main.hs
    
    This is the actual game code
-}

import Control.Monad (replicateM_, forM_)
import Control.Monad.Cont
import Control.Monad.State.Strict
import System.Random (randomRIO)

import Data.IORef
import Data.Lens.Common
import qualified Data.Map as Map

import qualified Graphics.UI.SDL as SDL
import Graphics.UI.SDL.Keysym
import qualified Graphics.UI.SDL.Image as SDLi

import GameSpace
import Util
import Plane

type SpriteMap = Map.Map String SDL.Surface

-- | The rate of movement in pix / ms
rate :: Double
rate = 1 / 100

-- | The size of the header info bar
header :: Int
header = 10

main = do
    putStr "Loading sprites ..."
    sprites <- loadSprites "res" 
        [ "Hobgoblin"
        , "Man"
        , "ManWithShield"
        ]
    putStrLn " done."
    putStr "Initializing SDL ..."
    SDL.init [SDL.InitVideo, SDL.InitEventthread, SDL.InitTimer]
    SDL.setVideoMode 640 480 32 
        [ SDL.DoubleBuf
        , SDL.HWSurface
        , SDL.Resizable
        ]
    SDL.setCaption "Hobgoblin" "hobgoblin"
    putStrLn " done."
    startGame sprites
    putStrLn "Thanks for playing!"

loadSprites :: String -> [String] -> IO SpriteMap
loadSprites dir paths = fmap Map.fromList $ mapM loadSprite paths
  where loadSprite imgName = do
            sprite <- SDLi.load $ dir ++ '/' : imgName ++ "_20x40.png"
            return (imgName, sprite)

testSDL :: SpriteMap -> IO ()
testSDL sprites = do
    screen <- SDL.getVideoSurface
    locRef <- newIORef (10, 10)
    forM_ (Map.elems sprites) $ \img -> do
        loc <- readIORef locRef
        SDL.blitSurface img Nothing screen $ Just 
            $ pointSize2Rect loc (20, 40)
        modifyIORef locRef $ modL fstLens (+30)
    SDL.flip screen
    eventLoop
  where eventLoop = do
            event <- SDL.waitEvent
            case event of
                SDL.Quit -> return ()
                _        -> eventLoop

startGame :: SpriteMap -> IO ()
startGame sprites = do
    putStrLn "Starting new game"
    execStateT (playGame sprites) newGame
    putStrLn "Game Over"
    promptNewGame >>= (startGame sprites ?? return ())

promptNewGame = return False

pollEvents :: IO [SDL.Event]
pollEvents = do
    event <- SDL.pollEvent
    return [] ?? fmap (event:) pollEvents $ event == SDL.NoEvent

getScreenSize :: IO Size
getScreenSize = do
    screen <- SDL.getVideoSurface
    let w = SDL.surfaceGetWidth screen
    let h = SDL.surfaceGetHeight screen
    return (w, h)

-- | Draw the initial Boxes for the Header
initHeader :: Maybe Int -> GameState IO ()
initHeader mw = do
    w <- case mw of
            Just w -> return w
            Nothing -> fmap (getL fstLens) $ lift getScreenSize
    screen <- lift SDL.getVideoSurface
    let pxlfmt = SDL.surfaceGetPixelFormat screen
    blue <- lift $ SDL.mapRGB pxlfmt 0 0 255
    green <- lift $ SDL.mapRGB pxlfmt 0 255 0
    white <- lift $ SDL.mapRGB pxlfmt 255 255 255
    lift $ SDL.fillRect screen (Just $ SDL.Rect 1 1 102 7) blue
    lift $ SDL.fillRect screen (Just $ SDL.Rect 105 1 102 7) green
    lift $ SDL.fillRect screen (Just $ SDL.Rect 0 9 w 1) white
    return ()

playGame :: SpriteMap -> GameState IO ()
playGame sprites = do
    -- We place the character in the middle and add an initial monster
    (w, h) <- lift getScreenSize
    setStateL gsLocation 
        (fromIntegral w / 2 - 10, 
        (fromIntegral h + fromIntegral header) / 2 - 20)
    genGoblin
    initHeader $ Just w
    -- We seed the game loop with 1 frame having passed
    gameLoop (1 / rate) sprites
    -- Add score reporting and high scores here
    lift $ putStr "Total Kills: "
    getStateL gsTotalKills >>= lift . print
    lift $ putStr "Score: "
    getStateL gsScore >>= lift . print

-- | Generates a random monster that does not hit the player
genGoblin :: GameState IO ()
genGoblin = do 
    (w, h) <- lift getScreenSize
    (px, py) <- getStateL gsLocation
    gx <- fmap (avoid px) $ lift $ randomRIO (0, fromIntegral w - 40)
    gy <- fmap (avoid py) $ lift $ randomRIO (0, fromIntegral h - 40)
    modStateL gsGoblins ((gx, gy):)
  where avoid obs val = ((val + 20) ?? val) $ 0 <= delta && delta < 20
          where delta = val - obs

gameLoop delta sprites = flip runContT return $ callCC $ \exit -> do
    startTime <- lift2 SDL.getTicks
    actions <- handleEvents exit
    lift $ do 
        clearScreen
        mKills <- gsUpdate (delta * rate) actions
        gsDrawSpace
        lift $ SDL.getVideoSurface >>= SDL.flip
        elapTime <- fmap (fromIntegral . subtract startTime) 
            $ lift SDL.getTicks
        case mKills of
            Nothing -> return ()
            Just kills -> do
                replicateM_ (kills * 2) genGoblin
                gameLoop elapTime sprites
  where clearScreen :: GameState IO ()
        clearScreen = do
            -- Prepare resources for drawing
            screen <- lift SDL.getVideoSurface
            let pxlfmt = SDL.surfaceGetPixelFormat screen
            black <- lift $ SDL.mapRGB pxlfmt 0 0 0
            -- Clear header
            lift $ SDL.fillRect screen (Just $ SDL.Rect 2 2 100 5) black
            lift $ SDL.fillRect screen (Just $ SDL.Rect 106 2 100 5) black
            -- Clear goblins
            goblins <- getStateL gsGoblins
            forM_ goblins $ lift . flip (SDL.fillRect screen) black 
                . Just . flip pointSize2Rect (20, 40)
            -- Clear Man
            loc <- getStateL gsLocation
            lift $ SDL.fillRect screen (Just $ pointSize2Rect loc (20, 40))
                black
            return ()
        gsDrawSpace :: GameState IO ()
        gsDrawSpace = do
            -- Prepare resources for drawing
            screen <- lift SDL.getVideoSurface
            let pxlfmt = SDL.surfaceGetPixelFormat screen
            lgreen <- lift $ SDL.mapRGB pxlfmt 127 255 127
            lblue  <- lift $ SDL.mapRGB pxlfmt 127 127 255
            -- Draw header
            power <- getStateL gsPower
            stamina <- getStateL gsStamina
            lift $ SDL.fillRect screen 
                (Just $ SDL.Rect 2 2 (floor power) 5) lblue
            lift $ SDL.fillRect screen 
                (Just $ SDL.Rect 106 2 (floor stamina) 5) lgreen
            -- Draw goblins
            goblins <- getStateL gsGoblins
            let (Just gobSurf) = Map.lookup "Hobgoblin" sprites
            forM_ goblins $ lift . SDL.blitSurface gobSurf Nothing screen
                . Just . flip pointSize2Rect (20, 40)
            -- Draw Man
            shield <- getStateL gsShield
            loc <- getStateL gsLocation
            let (Just manSurf) = flip Map.lookup sprites $ 
                    ("ManWithShield" ?? "Man") $ shield
            lift $ SDL.blitSurface manSurf Nothing screen $ Just $ 
                pointSize2Rect loc (20, 40)
            return ()
        -- Holy shit, Dat type!
        handleEvents :: (() -> ContT () (StateT GameSpace IO) ()) ->
            ContT () (StateT GameSpace IO) [Action]
        handleEvents exit = do
            incActsRef <- lift2 $ newIORef (id)
            otherActsRef <- lift2 $ newIORef (id)
            events <- lift2 $ pollEvents
            forM_ events $ \event -> do
              case event of
                SDL.Quit -> exit ()
                SDL.KeyDown Keysym{symKey=SDLK_SPACE} -> 
                    lift2 $ modifyIORef otherActsRef (.(ToggleShield:))
                _ -> return ()
            incActs <- lift2 $ readIORef incActsRef
            otherActs <- lift2 $ readIORef otherActsRef
            return $ (incActs . otherActs) []