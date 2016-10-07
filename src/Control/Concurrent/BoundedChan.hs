{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeFamilies              #-}

module Control.Concurrent.BoundedChan where

import           Control.Concurrent.MVar
import           Control.Exception.Base      (evaluate)
import           Control.Monad
import           Control.Monad.Primitive     (RealWorld)
import           Data.Array.IO
import           Data.IORef
import           Data.List                   (intercalate)
import           Data.Maybe                  (fromJust, isJust, isNothing)
import qualified Data.Vector                 as V
import qualified Data.Vector.Algorithms.Heap as VAH
import qualified Data.Vector.Generic         as VG
import qualified Data.Vector.Generic.Mutable as VGM
import qualified Data.Vector.Mutable         as VM
import           Data.Word
import           GHC.Prim                    (Any)
import           System.IO.Unsafe
import           System.Random
import           Unsafe.Coerce

-- TODO: need uique ID number
data Chan a = Chan
    { _qcount :: !(IORef Int)
    , _qsize  :: !Int
    , _buf    :: !(IOArray Int a)
    , _sendx  :: !(IORef Int)
    , _recvx  :: !(IORef Int)
    , _sendq  :: !(WaitQ)
    , _recvq  :: !(WaitQ)
    , _lock   :: !(MVar ())
    , _closed :: !(IORef Bool)
    , _id     :: !Word64
    }

data WaitQ = WaitQ
    { _first :: !(IORef (Maybe SomeSleeper))
    , _last  :: !(IORef (Maybe SomeSleeper))
    }

data SomeSleeper =
    forall a. SomeSleeper (Sleeper a)

data Sleeper a = forall b. Sleeper
    { _selectDone :: !(Maybe (IORef Bool))
    , _case       :: !(Maybe (Case b))
    , _next       :: !(IORef (Maybe SomeSleeper))
    , _prev       :: !(IORef (Maybe SomeSleeper))
    , _elem       :: !(Maybe (IORef a))
    , _chan       :: !(Chan a)
    , _park       :: !(MVar (Maybe (Sleeper a))) -- park, and when unparked, the awoken sleeper is given
    , _sid        :: !Word64
    }

data Case a
    = forall b. Recv !(Chan b)
                     !(Maybe b -> IO a)
    | forall b. Send !(Chan b)
                     !b
                     !(IO a)

caseChanId :: Case a -> Word64
caseChanId (Recv chan _)   = _id chan
caseChanId (Send chan _ _) = _id chan

caseWithChan :: Case a -> (forall b. Chan b -> c) -> c
caseWithChan (Recv chan _) f   = f chan
caseWithChan (Send chan _ _) f = f chan

{-# NOINLINE currIdRef #-}
currIdRef :: IORef Word64
currIdRef = unsafePerformIO (newIORef 0)

{-# NOINLINE currSIdRef #-}
currSIdRef :: IORef Word64
currSIdRef = unsafePerformIO (newIORef 0)

shuffleVector
    :: (VGM.MVector v e)
    => v RealWorld e -> IO ()
shuffleVector xs = do
    let size = VGM.length xs
    forM_ [1 .. size - 1] $
        \i -> do
            j <- randomRIO (0, i)
            vi <- VGM.read xs i
            vj <- VGM.read xs j
            VGM.write xs j vi
            VGM.write xs i vj

select
    :: forall a.
       String -> [Case a] -> Maybe (IO a) -> IO a
select name cases mdefault = do
    pollOrder <-
        do vec <- V.unsafeThaw (V.fromList cases)
           shuffleVector vec
           V.unsafeFreeze vec
    let ncases = VG.length pollOrder
    lockOrder <-
        do vec <- V.thaw (V.fromList cases)
           VAH.sortBy
               (\cas1 cas2 ->
                     caseChanId cas1 `compare` caseChanId cas2)
               vec
           V.unsafeFreeze vec
    selLock lockOrder
    let
        -- PASS 1
        pass1 n = do
            let cas = pollOrder VG.! n
            if n /= ncases
                then case cas of
                         Recv chan act -> do
                             ms <- dequeue (_sendq chan)
                             case ms of
                                 Just (SomeSleeper s) -> do
                                     elemRef <- newIORef undefined
                                     recv chan (unsafeCoerceSleeper s) (Just elemRef) (selUnlock lockOrder)
                                     val <- readIORef elemRef
                                     act (Just val)
                                 _ -> do
                                     qcount <- readIORef (_qcount chan)
                                     if qcount > 0
                                         then do
                                             recvx <- readIORef (_recvx chan)
                                             val <- readArray (_buf chan) recvx
                                             let recvx' =
                                                     let x = recvx + 1
                                                     in if x == _qsize chan
                                                            then 0
                                                            else x
                                             writeIORef (_recvx chan) $! recvx'
                                             writeIORef (_qcount chan) (qcount - 1)
                                             selUnlock lockOrder
                                             act (Just val)
                                         else do
                                             isClosed <- readIORef (_closed chan)
                                             if isClosed
                                                 then do
                                                     selUnlock lockOrder
                                                     act Nothing
                                                 else do
                                                     pass1 (n + 1)
                         Send chan val act -> do
                             isClosed <- readIORef (_closed chan)
                             if isClosed
                                 then do
                                     selUnlock lockOrder
                                     fail "send on closed channel"
                                 else do
                                     ms <- dequeue (_recvq chan)
                                     case ms of
                                         Just (SomeSleeper s) -> do
                                             send chan (unsafeCoerceSleeper s) val (selUnlock lockOrder)
                                             act
                                         _ -> do
                                             qcount <- readIORef (_qcount chan)
                                             if qcount < _qsize chan
                                                 then do
                                                     sendx <- readIORef (_sendx chan)
                                                     writeArray (_buf chan) sendx val
                                                     let !sendx' =
                                                             let x = sendx + 1
                                                             in if x == _qsize chan
                                                                    then 0
                                                                    else x
                                                     writeIORef (_sendx chan) sendx'
                                                     writeIORef (_qcount chan) (qcount + 1)
                                                     selUnlock lockOrder
                                                     act
                                                 else do
                                                     pass1 (n + 1)
                else case mdefault of
                         Just def -> do
                             selUnlock lockOrder
                             def
                         _ -> do
                             -- PASS 2
                             park <- newEmptyMVar
                             selectDone <- newIORef False
                             ss <-
                                 V.generateM
                                     ncases
                                     (\n -> do
                                          let cas = lockOrder V.! n
                                          caseWithChan
                                              cas
                                              (\chan -> do
                                                   case cas of
                                                       Send _ val _ -> do
                                                           next <- newIORef Nothing
                                                           prev <- newIORef Nothing
                                                           elemRef <- newIORef (unsafeCoerce val)
                                                           id <-
                                                               atomicModifyIORef' -- TODO: delete once we have ptr equality
                                                                   currSIdRef
                                                                   (\currId ->
                                                                         (currId + 1, currId))
                                                           let s =
                                                                   SomeSleeper
                                                                       (Sleeper
                                                                            (Just selectDone)
                                                                            (Just (unsafeCoerceCase cas))
                                                                            next
                                                                            prev
                                                                            (Just elemRef)
                                                                            (unsafeCoerceChan chan)
                                                                            park
                                                                            id)
                                                           enqueue (_sendq chan) s
                                                           return s
                                                       Recv _ _ -> do
                                                           next <- newIORef Nothing
                                                           prev <- newIORef Nothing
                                                           elemRef <- newIORef undefined
                                                           id <-
                                                               atomicModifyIORef' -- TODO: delete once we have ptr equality
                                                                   currSIdRef
                                                                   (\currId ->
                                                                         (currId + 1, currId))
                                                           let s =
                                                                   SomeSleeper
                                                                       (Sleeper
                                                                            (Just selectDone)
                                                                            (Just (unsafeCoerceCase cas))
                                                                            next
                                                                            prev
                                                                            (Just elemRef)
                                                                            (unsafeCoerceChan chan)
                                                                            park
                                                                            id)
                                                           enqueue (_recvq chan) s
                                                           return s))
                             selUnlock lockOrder
                             ms <- takeMVar park
                             selLock lockOrder
                             let pass3 n = do
                                     case ss VG.! n of
                                         someS@(SomeSleeper s) ->
                                             --case _case s of
                                             case s of
                                                 (Sleeper _ cas _ _ _ _ _ _) ->
                                                     case cas of
                                                         Just (Send _ _ _) -> do
                                                             --
                                                             dequeueSleeper
                                                                 (_sendq (_chan s))
                                                                 someS
                                                         Just (Recv _ _) -> do
                                                             dequeueSleeper (_recvq (_chan s)) someS
                                     when ((n + 1) /= ncases) (pass3 (n + 1))
                             pass3 0
                             case ms of
                                 Just s -> do
                                     --case (_case s) of
                                     case s of
                                         (Sleeper _ cas _ _ _ _ _ _) ->
                                             case cas of
                                                 Just (Send chan _ act) -> do
                                                     selUnlock lockOrder
                                                     unsafeCoerceSendAction act
                                                 Just (Recv chan act) -> do
                                                     val <- readIORef (fromJust (_elem s))
                                                     selUnlock lockOrder
                                                     unsafeCoerceRecvAction act (Just val) -- XXXXX val is nothing?!?!?!
                                 _ -> do
                                     -- channel closed, restart loop
                                     pass1
                                         0
    pass1 0

unsafeCoerceSendAction :: IO a -> IO b
unsafeCoerceSendAction = unsafeCoerce

unsafeCoerceRecvAction :: (Maybe b -> IO a) -> (Maybe d -> IO c)
unsafeCoerceRecvAction = unsafeCoerce

unsafeCoerceSleeper :: Sleeper a -> Sleeper b
unsafeCoerceSleeper = unsafeCoerce

unsafeCoerceChan :: Chan a -> Chan b
unsafeCoerceChan = unsafeCoerce

unsafeCoerceCase :: Case a -> Case b
unsafeCoerceCase = unsafeCoerce

lockCase cas =
    caseWithChan
        cas
        (\chan ->
              takeMVar (_lock chan))

unlockCase cas =
    caseWithChan
        cas
        (\chan ->
              putMVar (_lock chan) ())

selLock
    :: (VG.Vector v e, e ~ Case a)
    => v (Case a) -> IO ()
selLock vec = do
    go 0 maxBound
  where
    len = VG.length vec
    go n prevId = do
        let cas = (vec VG.! n)
        if n == len - 1
            then do
                lockCase cas
            else do
                when (caseChanId cas /= prevId) $ do lockCase cas
                go (n + 1) (caseChanId cas)

selUnlock
    :: (VG.Vector v e, e ~ Case a)
    => v (Case a) -> IO ()
selUnlock vec = do
    go (len - 1) maxBound
  where
    len = VG.length vec
    go n prevId = do
        let cas = (vec VG.! n)
        if n == 0
            then do
                unlockCase cas
            else do
                when (caseChanId cas /= prevId) $ do (unlockCase cas)
                go (n - 1) (caseChanId cas)

mkChan :: Int -> IO (Chan a)
mkChan size = do
    ary <- newArray_ (0, size - 1)
    qcount <- newIORef 0
    sendx <- newIORef 0
    recvx <- newIORef 0
    sendq_first <- newIORef Nothing
    sendq_last <- newIORef Nothing
    recvq_first <- newIORef Nothing
    recvq_last <- newIORef Nothing
    lock <- newMVar ()
    closed <- newIORef False
    id <-
        atomicModifyIORef'
            currIdRef
            (\currId ->
                  (currId + 1, currId))
    return
        Chan
        { _qcount = qcount
        , _qsize = size
        , _buf = ary
        , _sendx = sendx
        , _recvx = recvx
        , _sendq = WaitQ sendq_first sendq_last
        , _recvq = WaitQ recvq_first recvq_last
        , _lock = lock
        , _closed = closed
        , _id = id
        }

chanSend :: Chan a -> a -> IO ()
chanSend chan val = void $ chanSendInternal chan val True

chanSendInternal :: Chan a -> a -> Bool -> IO Bool
chanSendInternal chan val block = do
    isClosed <- readIORef (_closed chan)
    recvq_first <- readIORef (_first (_recvq chan))
    qcount <- readIORef (_qcount chan)
    if not block && not isClosed && ((_qsize chan == 0 && isJust recvq_first) || (_qsize chan > 0 && qcount == _qsize chan))
        then return False
        else do
            takeMVar (_lock chan)
            isClosed <- readIORef (_closed chan)
            if isClosed
                then do
                    putMVar (_lock chan) ()
                    fail "send on closed channel"
                else do
                    ms <- dequeue (_recvq chan)
                    case ms of
                        Just (SomeSleeper s) -> do
                            send chan (unsafeCoerceSleeper s) val (putMVar (_lock chan) ())
                            return True
                        Nothing -> do
                            qcount <- readIORef (_qcount chan)
                            if qcount < _qsize chan
                                then do
                                    sendx <- readIORef (_sendx chan)
                                    writeArray (_buf chan) sendx val
                                    writeIORef (_sendx chan) $! (sendx + 1)
                                    let sendx' = sendx + 1
                                    if sendx' == _qsize chan
                                        then writeIORef (_sendx chan) 0
                                        else writeIORef (_sendx chan) $! sendx'
                                    writeIORef (_qcount chan) (qcount + 1)
                                    putMVar (_lock chan) ()
                                    return True
                                else if not block
                                         then do
                                             putMVar (_lock chan) ()
                                             return False
                                         else do
                                             next <- newIORef Nothing
                                             prev <- newIORef Nothing
                                             elem <- newIORef val
                                             park <- newEmptyMVar -- we're about to park
                                             id <-
                                                 atomicModifyIORef' -- TODO: delete once we have ptr equality
                                                     currSIdRef
                                                     (\currId ->
                                                           (currId + 1, currId))
                                             let s = (SomeSleeper (Sleeper Nothing Nothing next prev (Just elem) chan park id))
                                             enqueue (_sendq chan) s
                                             putMVar (_lock chan) ()
                                             ms' <- takeMVar park
                                             case ms' of
                                                 Nothing -> do
                                                     isClosed <- readIORef (_closed chan)
                                                     unless isClosed (fail "chansend: spurious wakeup")
                                                     fail "send on closed channel"
                                                 _ -> return True

send :: Chan a -> Sleeper a -> a -> IO () -> IO ()
send chan s val unlock = do
    case _elem s of
        Just elemRef -> do
            writeIORef elemRef val
        _ -> do
            return ()
    unlock
    putMVar (_park s) (Just s) -- unpark

closeChan :: Chan a -> IO ()
closeChan chan = do
    takeMVar (_lock chan)
    isClosed <- readIORef (_closed chan)
    when isClosed $
        do putMVar (_lock chan) ()
           fail "close of closed channel"
    writeIORef (_closed chan) True
    ss <- releaseReaders [] chan
    ss <- releaseWriters ss chan
    putMVar (_lock chan) ()
    wakeSleepers ss
  where
    releaseReaders ss chan = do
        ms <- dequeue (_recvq chan)
        case ms of
            Nothing -> return ss
            Just s  -> releaseReaders (s : ss) chan
    releaseWriters ss chan = do
        ms <- dequeue (_sendq chan)
        case ms of
            Nothing -> return ss
            Just s  -> releaseReaders (s : ss) chan
    wakeSleepers ss =
        forM_
            ss
            (\(SomeSleeper s) ->
                  putMVar (_park s) Nothing)

chanRecv :: Chan a -> IO (Maybe a)
chanRecv chan = do
    ref <- newIORef undefined
    (selected,received) <- chanRecvInternal chan (Just ref) True
    if received
        then Just <$> readIORef ref
        else return Nothing

chanRecvInternal :: Chan a -> Maybe (IORef a) -> Bool -> IO (Bool, Bool)
chanRecvInternal chan melemRef block = do
    sendq_first <- readIORef (_first (_sendq chan))
    qcount <- atomicReadIORef (_qcount chan)
    isClosed <- atomicReadIORef (_closed chan)
    if not block && ((_qsize chan == 0 && isNothing sendq_first) || (_qsize chan > 0 && qcount == _qsize chan)) && not isClosed
        then return (False, False)
        else do
            takeMVar (_lock chan)
            isClosed <- readIORef (_closed chan)
            qcount <- readIORef (_qcount chan)
            if isClosed && qcount == 0
                then do
                    putMVar (_lock chan) ()
                    return (True, False)
                else do
                    ms <- dequeue (_sendq chan)
                    case ms of
                        Just (SomeSleeper s) -> do
                            recv chan (unsafeCoerceSleeper s) melemRef (putMVar (_lock chan) ())
                            return (True, True)
                        _ ->
                            if qcount > 0
                                then do
                                    recvx <- readIORef (_recvx chan)
                                    !val <- readArray (_buf chan) recvx
                                    case melemRef of
                                        Just elemRef -> writeIORef elemRef val
                                        _ -> return ()
                                    let recvx' =
                                            let x = recvx + 1
                                            in if x == _qsize chan
                                                   then 0
                                                   else x
                                    writeIORef (_recvx chan) $! recvx'
                                    modifyIORef' (_qcount chan) (subtract 1)
                                    putMVar (_lock chan) ()
                                    return (True, True)
                                else if not block
                                         then do
                                             putMVar (_lock chan) ()
                                             return (False, False)
                                         else do
                                             next <- newIORef Nothing
                                             prev <- newIORef Nothing
                                             park <- newEmptyMVar -- we're about to park
                                             id <-
                                                 atomicModifyIORef' -- TODO: delete once we have ptr equality
                                                     currSIdRef
                                                     (\currId ->
                                                           (currId + 1, currId))
                                             let s = SomeSleeper (Sleeper Nothing Nothing next prev melemRef chan park id)
                                             enqueue (_recvq chan) s
                                             putMVar (_lock chan) ()
                                             ms' <- takeMVar park -- park
                                             return (True, isJust ms')

recv :: Chan a -> Sleeper a -> Maybe (IORef a) -> IO () -> IO ()
recv chan s melemRef unlock = do
    if _qsize chan == 0
        then case melemRef of
                 Just elemRef -> do
                     val <- readIORef (fromJust (_elem s))
                     evaluate val
                     writeIORef elemRef val
                 _ -> return ()
        else do
            recvx <- readIORef (_recvx chan)
            !val <- readArray (_buf chan) recvx
            case melemRef of
                Just elemRef -> writeIORef elemRef val
                _            -> return ()
            val' <- readIORef (fromJust (_elem s))
            writeArray (_buf chan) recvx val'
            let recvx' =
                    let x = recvx + 1
                    in if x == _qsize chan
                           then 0
                           else x
            writeIORef (_recvx chan) $! recvx'
            writeIORef (_sendx chan) $! recvx'
    unlock
    putMVar (_park s) (Just s) -- unpark

enqueue :: WaitQ -> SomeSleeper -> IO ()
enqueue q someS@(SomeSleeper s) = do
    writeIORef (_next s) Nothing
    mx <- readIORef . _last $ q
    case mx of
        Nothing -> do
            writeIORef (_prev s) Nothing
            writeIORef (_first q) (Just someS)
            writeIORef (_last q) (Just someS)
        Just someX@(SomeSleeper x) -> do
            writeIORef (_prev s) (Just someX)
            writeIORef (_next x) (Just someS)
            writeIORef (_last q) (Just someS)

dequeue :: WaitQ -> IO (Maybe SomeSleeper)
dequeue q = do
    ms <- readIORef (_first q)
    case ms of
        Nothing -> return Nothing
        Just someS@(SomeSleeper s) -> do
            my <- readIORef (_next s)
            case my of
                Nothing -> do
                    writeIORef (_first q) Nothing
                    writeIORef (_last q) Nothing
                Just someY@(SomeSleeper y) -> do
                    writeIORef (_prev y) Nothing
                    writeIORef (_first q) (Just someY)
                    writeIORef (_next s) Nothing
            case _selectDone s of
                Nothing -> return (Just someS)
                Just doneRef -> do
                    done <- readIORef doneRef
                    if not done
                        then do
                            -- attempt to set the "selectdone" flag and return
                            -- the sleeper.
                            -- if someone beat us to it, try dequeuing again.
                            oldDone <-
                                atomicModifyIORef'
                                    doneRef
                                    (\oldDone ->
                                          (True, oldDone))
                            if oldDone
                                then do
                                    -- we did *not* signal; try again
                                    dequeue
                                        q
                                else do
                                    -- signalled! done.
                                    return
                                        (Just someS)
                        else do
                            -- we did *not* signal; try again
                            dequeue
                                q

{-# INLINE atomicReadIORef #-}

atomicReadIORef :: IORef a -> IO a
atomicReadIORef ref =
    atomicModifyIORef'
        ref
        (\oldVal ->
              (oldVal, oldVal))

-- TODO: Consider (carefully) using pointer equality.
eqSleeper
    :: Sleeper a -> Sleeper b -> Bool
eqSleeper s1 s2 = _sid s1 == _sid s2

dequeueSleeper :: WaitQ -> SomeSleeper -> IO ()
dequeueSleeper q someS@(SomeSleeper s) = do
    mx <- readIORef (_prev s)
    my <- readIORef (_next s)
    case mx of
        Just someX@(SomeSleeper x) ->
            case my of
                Just someY@(SomeSleeper y) -> do
                    writeIORef (_next x) (Just someY)
                    writeIORef (_prev y) (Just someX)
                    writeIORef (_next s) Nothing
                    writeIORef (_prev s) Nothing
                _ -> do
                    writeIORef (_next x) Nothing
                    writeIORef (_last q) (Just someX)
                    writeIORef (_prev s) Nothing
        _ ->
            case my of
                Just someY@(SomeSleeper y) -> do
                    writeIORef (_prev y) Nothing
                    writeIORef (_first q) (Just someY)
                    writeIORef (_next s) Nothing
                _ -> do
                    mfirst <- readIORef (_first q)
                    case mfirst of
                        Just someFirst@(SomeSleeper first) ->
                            when (first `eqSleeper` s) $
                            do writeIORef (_first q) Nothing
                               writeIORef (_last q) Nothing
                        _ -> return ()

--------------------------------------------------------------------------------
-- misc. debug utils
waitqToList
    :: WaitQ -> IO [SomeSleeper]
waitqToList q = do
    ms <- readIORef (_first q)
    case ms of
        Just s -> sleeperChain s
        _      -> return []

sleeperChain :: SomeSleeper -> IO [SomeSleeper]
sleeperChain someS@(SomeSleeper s) = do
    mnext <- readIORef (_next s)
    case mnext of
        Just next -> do
            ss <- sleeperChain next
            return (someS : ss)
        _ -> return [someS]

printWaitQ :: WaitQ -> IO ()
printWaitQ q = do
    ss <- waitqToList q
    let chain =
            intercalate
                "->"
                (map
                     (\(SomeSleeper s) ->
                           "(SID: " ++ show (_sid s) ++ ", CID: " ++ show (_id (_chan s)) ++ ")")
                     ss)
    putStrLn $ "WAITQ: " ++ chain
