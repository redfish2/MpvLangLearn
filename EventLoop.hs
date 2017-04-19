module EventLoop where

import Control.Monad.State
import Loops

type MpvLoop = Loop ()

data MpvStatus =
    MpvStart --begin
  | MpvInLoop -- loop action run and inside of a loop
  | MpvOutOfLoop -- defaultNoSrtAction run and outside of loop
  | MpvEndLoop -- loop finished, and first of nextLoops moved to priorLoops, but
               -- next action not run (which would be defaultNoSrtAction or the
               -- next loops action, if outside or inside another loop respectively)
  | MpvShutdown -- in shutdown state (the user quit)
  deriving (Show)
data MpvState = MpvState {
              priorLoops :: [MpvLoop], --loops already run
              nextLoops :: [MpvLoop], --loops to run later (or currently running)
              status :: MpvStatus,
              defaultNoSrtAction :: IO (), -- if a loop finishes and there isn't another
                                       -- loop starting, we do this default action here
              readTimeAction :: IO (Maybe Double), -- returns the current time. May return nothing
                                              -- if unknown
              waitAction :: Double -> IO Bool, -- waits the given period of time (or less)
                                              -- returns true if user requested shutdown
              seekAction :: MpvLoop -> IO (), --action when we need to seek to the start of a loop 
              playAction :: MpvLoop -> IO () --action to play the loop
           }

instance Show MpvState where
  show s = "MpvState { priorLoops="++show(priorLoops s)++", nextLoops="++show(nextLoops s)++", status="++show(status s)++" }"
      

type MpvM = StateT MpvState IO

event_loop :: MpvState -> IO ()
--event_loop = undefined
event_loop mpvState = runStateT doit mpvState >> return ()
  where
    waitAndLoop :: Double -> MpvM ()
    waitAndLoop wait_time =
      do
        st <- get
        ifextract (liftIO $ (waitAction st) wait_time) id
          (put (st { status = MpvShutdown }))
          (return ())
        -- (mpv_wait_event (ctx st) $ realToFrac wait_time) >>= peek

    --return true if waited, or false if didn't
    waitForTime :: Double -> Double -> MpvM Bool
    waitForTime ct et =
      let timeToWait = (et-ct)
          in
            do
              if (timeToWait > 0)
              then
                waitAndLoop timeToWait >> return True
              else
                lift $ return False

    --extract result from a monad op and then branch based on the result
    ifextract :: (MpvM a) -> (a -> Bool) -> (MpvM b) -> (MpvM b) -> (MpvM b)
    ifextract cond f tru fals =
        cond >>= (\res -> if (f res) then tru else fals)

    doit :: MpvM ()
    doit =
      do
        st <- get
--        time <- liftIO $ mpv_get_property_double ctx "time-pos"
        time <- liftIO $ (readTimeAction st)
        jtime <- return $ case time of
             Nothing -> 0.0
             (Just t) -> t

        --find the current loop
        loop <- return (head (nextLoops st))

        --perform the next action depending on the state
        case (status st) of
          MpvStart ->
              do
                liftIO $ (defaultNoSrtAction st)
                put $ st {status=MpvOutOfLoop}
          MpvOutOfLoop ->
              do
                ifextract (waitForTime jtime (startTime loop)) not
                  (do
                    liftIO $ (playAction st loop)
                    put $ st {status=MpvInLoop})
                  (return ())
          MpvInLoop ->
              do
                --if we wait at all, we go back to the start and reread the time, etc.
                --otherwise, we go ahead and update the state
                ifextract (waitForTime jtime (endTime loop)) not
                  (do
                     put $ st {status=MpvEndLoop,
                               priorLoops = loop : (priorLoops st),
                               nextLoops = tail (nextLoops st)
                              })
                  (return ())
          MpvEndLoop ->
              do
                if jtime < (startTime loop) -- if the next loop doesn't start yet
                then
                  do
                    --go to default mode and let it play
                    liftIO $ (defaultNoSrtAction st)
                    put $ st {status=MpvOutOfLoop}
                else
                  do
                    --seek (backwards) to the start of the loop and play it
                    liftIO $ (seekAction st loop) >> (playAction st loop)
                    put $ st {status=MpvInLoop}

        doit --restart the event loop

bigTime = 99999999

createInitialMpvState loops defaultNoSrtAction readTimeAction waitAction seekAction playAction =
  MpvState []
           (loops ++ [(Loop () bigTime bigTime)]) -- we add an ending loop which keeps the system playing until the end of the movie
           MpvStart
           defaultNoSrtAction
           readTimeAction
           waitAction
           seekAction
           playAction
