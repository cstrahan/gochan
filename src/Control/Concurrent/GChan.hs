-- {-# OPTIONS_GHC  #-}
-- -fexpose-all-unfoldings
{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeFamilies              #-}

module Control.Concurrent.GChan where

import           Control.Concurrent.MVar
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

data Chan a = Chan
    { _qcount :: {-# UNPACK #-} !(IORef Int)
    , _qsize  :: {-# UNPACK #-} !Int
    , _buf    :: {-# UNPACK #-} !(IOArray Int a)
    , _sendx  :: {-# UNPACK #-} !(IORef Int)
    , _recvx  :: {-# UNPACK #-} !(IORef Int)
    , _sendq  :: {-# UNPACK #-} !WaitQ
    , _recvq  :: {-# UNPACK #-} !WaitQ
    , _lock   :: {-# UNPACK #-} !(MVar ())
    , _closed :: {-# UNPACK #-} !(IORef Bool)
    , _id     :: {-# UNPACK #-} !Word64
    }

data WaitQ = WaitQ
    { _first :: {-# UNPACK #-} !(IORef (Maybe SomeSleeper))
    , _last  :: {-# UNPACK #-} !(IORef (Maybe SomeSleeper))
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

data Result a
    = Msg a
    | Closed

data Case a
    = forall b. Recv !(Chan b)
                     !(Result b -> IO a)
    | forall b. Send !(Chan b)
                     !b
                     !(IO a)

{-# INLINE caseChanId #-}

caseChanId :: Case a -> Word64
caseChanId (Recv chan _)   = _id chan
caseChanId (Send chan _ _) = _id chan

{-# NOINLINE currIdRef #-}

currIdRef :: IORef Word64
currIdRef = unsafePerformIO (newIORef 0)

{-# NOINLINE currSIdRef #-}

currSIdRef :: IORef Word64
currSIdRef = unsafePerformIO (newIORef 0)

shuffleVector
    :: (VGM.MVector v e)
    => v RealWorld e -> IO ()
shuffleVector !xs = do
    let !size = VGM.length xs
    forM_ [1 .. size - 1] $
        \i -> do
            j <- randomRIO (0, i)
            vi <- VGM.read xs i
            vj <- VGM.read xs j
            VGM.write xs j vi
            VGM.write xs i vj

select
    :: forall a.
       [Case a] -> Maybe (IO a) -> IO a
select cases mdefault = do
    -- randomize the poll order to enforce fairness.
    !pollOrder <-
        -- for reasons unknown to me, we get better performance when we don't
        -- explicitly lift out the common fromList expression.
        do vec <- V.thaw (V.fromList cases)
           shuffleVector vec
           V.unsafeFreeze vec
    let !ncases = VG.length pollOrder
    -- we need to aquire locks in a consistent order so we don't deadlock.
    !lockOrder <-
        do vec <- V.thaw (V.fromList cases)
           VAH.sortBy
               (\cas1 cas2 ->
                     caseChanId cas1 `compare` caseChanId cas2)
               vec
           V.unsafeFreeze vec
    selLock lockOrder
    -- PASS 1 - attempt to dequeue a Suspend from one of the channels.
    let pass1 !n = do
            if n /= ncases
                then case pollOrder VG.! n of
                         Recv chan act -> do
                             ms <- dequeue (_sendq chan)
                             case ms of
                                 Just (SomeSleeper s) -> do
                                     elemRef <- newIORef undefined
                                     recv chan (unsafeCoerceSleeper s) (Just elemRef) (selUnlock lockOrder)
                                     val <- readIORef elemRef
                                     act (Msg val)
                                 _ -> do
                                     !qcount <- readIORef (_qcount chan)
                                     if qcount > 0
                                         then do
                                             !recvx <- readIORef (_recvx chan)
                                             val <- readArray (_buf chan) recvx
                                             let !recvx' =
                                                     let !x = recvx + 1
                                                     in if x == _qsize chan
                                                            then 0
                                                            else x
                                             writeIORef (_recvx chan) $! recvx'
                                             writeIORef (_qcount chan) (qcount - 1)
                                             selUnlock lockOrder
                                             act (Msg val)
                                         else do
                                             !isClosed <- readIORef (_closed chan)
                                             if isClosed
                                                 then do
                                                     selUnlock lockOrder
                                                     act Closed
                                                 else do
                                                     pass1 (n + 1)
                         Send chan val act -> do
                             !isClosed <- readIORef (_closed chan)
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
                                             !qcount <- readIORef (_qcount chan)
                                             if qcount < _qsize chan
                                                 then do
                                                     !sendx <- readIORef (_sendx chan)
                                                     writeArray (_buf chan) sendx val
                                                     let !sendx' =
                                                             let !x = sendx + 1
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
                             -- PASS 2 - enqueue a Suspend for each case.
                             --
                             -- the shared 'park' MVark is used wake up this
                             -- thread.
                             park <- newEmptyMVar
                             -- the shared 'selectDone' IORef allows the other
                             -- threads to know who won the race to wake us up
                             -- (via CAS).
                             selectDone <- newIORef False
                             ss <-
                                 V.generateM
                                     ncases
                                     (\n -> do
                                          next <- newIORef Nothing
                                          prev <- newIORef Nothing
                                          id <-
                                              atomicModifyIORef'
                                                  currSIdRef
                                                  (\currId ->
                                                        (currId + 1, currId))
                                          case lockOrder V.! n of
                                              cas@(Send chan val _) -> do
                                                  elemRef <- newIORef (unsafeCoerce val)
                                                  let !s =
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
                                              cas@(Recv chan _) -> do
                                                  elemRef <- newIORef undefined
                                                  let !s =
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
                                                  return s)
                             selUnlock lockOrder
                             ms <- takeMVar park
                             selLock lockOrder
                             -- PASS 3 - dequeue each Suspend we enqueued
                             -- earlier.
                             let pass3 !n = do
                                     case ss VG.! n of
                                         someS@(SomeSleeper s) ->
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
                                     case s of
                                         (Sleeper _ cas _ _ _ _ _ _) ->
                                             case cas of
                                                 Just (Send chan _ act) -> do
                                                     selUnlock lockOrder
                                                     unsafeCoerceSendAction act
                                                 Just (Recv chan act) -> do
                                                     !val <- readIORef (fromJust (_elem s))
                                                     selUnlock lockOrder
                                                     unsafeCoerceRecvAction act (Msg val)
                                 _ -> do
                                     -- channel closed, restart loop to figure
                                     -- out which one.
                                     pass1 0
    pass1 0

{-# INLINE unsafeCoerceSendAction #-}

unsafeCoerceSendAction :: IO a -> IO b
unsafeCoerceSendAction = unsafeCoerce

{-# INLINE unsafeCoerceRecvAction #-}

unsafeCoerceRecvAction :: (Result b -> IO a) -> (Result d -> IO c)
unsafeCoerceRecvAction = unsafeCoerce

{-# INLINE unsafeCoerceSleeper #-}

unsafeCoerceSleeper :: Sleeper a -> Sleeper b
unsafeCoerceSleeper = unsafeCoerce

{-# INLINE unsafeCoerceChan #-}

unsafeCoerceChan :: Chan a -> Chan b
unsafeCoerceChan = unsafeCoerce

{-# INLINE unsafeCoerceCase #-}

unsafeCoerceCase :: Case a -> Case b
unsafeCoerceCase = unsafeCoerce

{-# INLINE lockCase #-}

lockCase :: Case a -> IO ()
lockCase (Recv chan _)   = takeMVar (_lock chan)
lockCase (Send chan _ _) = takeMVar (_lock chan)

{-# INLINE unlockCase #-}

unlockCase :: Case a -> IO ()
unlockCase (Recv chan _)   = putMVar (_lock chan) ()
unlockCase (Send chan _ _) = putMVar (_lock chan) ()

selLock
    :: (VG.Vector v e, e ~ Case a)
    => v (Case a) -> IO ()
selLock !vec = do
    go 0 maxBound
  where
    len = VG.length vec
    go n prevId = do
        let !cas = vec VG.! n
        if n == len - 1
            then do
                lockCase cas
            else do
                when (caseChanId cas /= prevId) $ do lockCase cas
                go (n + 1) (caseChanId cas)

selUnlock
    :: (VG.Vector v e, e ~ Case a)
    => v (Case a) -> IO ()
selUnlock !vec = do
    go (len - 1) maxBound
  where
    len = VG.length vec
    go n prevId = do
        let !cas = vec VG.! n
        if n == 0
            then do
                unlockCase cas
            else do
                when (caseChanId cas /= prevId) $ do (unlockCase cas)
                go (n - 1) (caseChanId cas)

mkChan :: Int -> IO (Chan a)
mkChan !size = do
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
chanSend !chan !val = void $ chanSendInternal chan val True

chanSendAsync :: Chan a -> a -> IO Bool
chanSendAsync !chan !val = chanSendInternal chan val False

chanSendInternal :: Chan a -> a -> Bool -> IO Bool
chanSendInternal !chan !val !block = do
    !isClosed <- readIORef (_closed chan)
    !recvq_first <- readIORef (_first (_recvq chan))
    !qcount <- readIORef (_qcount chan)
    -- Fast path: check for failed non-blocking operation without acquiring the lock.
    if not block && not isClosed && ((_qsize chan == 0 && isJust recvq_first) || (_qsize chan > 0 && qcount == _qsize chan))
        then return False
        else do
            takeMVar (_lock chan)
            !isClosed <- readIORef (_closed chan)
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
                            !qcount <- readIORef (_qcount chan)
                            if qcount < _qsize chan
                                then do
                                    !sendx <- readIORef (_sendx chan)
                                    writeArray (_buf chan) sendx val
                                    writeIORef (_sendx chan) $! (sendx + 1)
                                    let !sendx' = sendx + 1
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
                                                 atomicModifyIORef'
                                                     currSIdRef
                                                     (\currId ->
                                                           (currId + 1, currId))
                                             let !s = (SomeSleeper (Sleeper Nothing Nothing next prev (Just elem) chan park id))
                                             enqueue (_sendq chan) s
                                             putMVar (_lock chan) ()
                                             ms' <- takeMVar park
                                             case ms' of
                                                 Nothing -> do
                                                     !isClosed <- readIORef (_closed chan)
                                                     unless isClosed (fail "chansend: spurious wakeup")
                                                     fail "send on closed channel"
                                                 _ -> return True

send :: Chan a -> Sleeper a -> a -> IO () -> IO ()
send !chan !s !val !unlock = do
    case _elem s of
        Just elemRef -> do
            writeIORef elemRef val
        _ -> do
            return ()
    unlock
    putMVar (_park s) (Just s) -- unpark

closeChan :: Chan a -> IO ()
closeChan !chan = do
    takeMVar (_lock chan)
    !isClosed <- readIORef (_closed chan)
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

chanRecvAsync :: Chan a -> IO (Maybe (Result a))
chanRecvAsync !chan = do
    ref <- newIORef undefined
    chanRecvInternal chan (Just ref) False >>=
        \case
            (False,_) -> return Nothing
            (True,False) -> return (Just Closed)
            (True,True) -> Just <$> Msg <$> readIORef ref

chanRecv :: Chan a -> IO (Result a)
chanRecv !chan = do
    ref <- newIORef undefined
    chanRecvInternal chan (Just ref) True >>=
        \case
            (_,False) -> return Closed
            (_,True) -> Msg <$> readIORef ref

chanRecvInternal :: Chan a -> Maybe (IORef a) -> Bool -> IO (Bool, Bool)
chanRecvInternal !chan !melemRef !block = do
    -- Fast path: check for failed non-blocking operation without acquiring the lock.
    -- WARNING: the order of these reads is important.
    !sendq_first <- readIORef (_first (_sendq chan))
    !qcount <- atomicReadIORef (_qcount chan)
    !isClosed <- atomicReadIORef (_closed chan)
    if not block && ((_qsize chan == 0 && isNothing sendq_first) || (_qsize chan > 0 && qcount == _qsize chan)) && not isClosed
        then return (False, False)
        else do
            takeMVar (_lock chan)
            !isClosed <- readIORef (_closed chan)
            !qcount <- readIORef (_qcount chan)
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
                                    !recvx <- readIORef (_recvx chan)
                                    val <- readArray (_buf chan) recvx
                                    case melemRef of
                                        Just elemRef -> writeIORef elemRef val
                                        _ -> return ()
                                    let !recvx' =
                                            let !x = recvx + 1
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
                                                 atomicModifyIORef'
                                                     currSIdRef
                                                     (\currId ->
                                                           (currId + 1, currId))
                                             let !s = SomeSleeper (Sleeper Nothing Nothing next prev melemRef chan park id)
                                             enqueue (_recvq chan) s
                                             putMVar (_lock chan) ()
                                             ms' <- takeMVar park -- park
                                             return (True, isJust ms')

recv :: Chan a -> Sleeper a -> Maybe (IORef a) -> IO () -> IO ()
recv !chan !s !melemRef !unlock = do
    if _qsize chan == 0
        then case melemRef of
                 Just elemRef -> do
                     !val <- readIORef (fromJust (_elem s))
                     writeIORef elemRef val
                 _ -> return ()
        else do
            !recvx <- readIORef (_recvx chan)
            val <- readArray (_buf chan) recvx
            case melemRef of
                Just elemRef -> writeIORef elemRef val
                _            -> return ()
            !val' <- readIORef (fromJust (_elem s))
            writeArray (_buf chan) recvx val'
            let !recvx' =
                    let !x = recvx + 1
                    in if x == _qsize chan
                           then 0
                           else x
            writeIORef (_recvx chan) $! recvx'
            writeIORef (_sendx chan) $! recvx'
    unlock
    putMVar (_park s) (Just s) -- unpark

-- enqueue a Supsend.
enqueue
    :: WaitQ -> SomeSleeper -> IO ()
enqueue !q someS@(SomeSleeper s) = do
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

-- dequeue each Suspend until one is found that can be resumed;
-- if we dequeue one that participates in a select, and it is already
-- flagged as selected, continue dequeuing.
dequeue
    :: WaitQ -> IO (Maybe SomeSleeper)
dequeue !q = do
    !ms <- readIORef (_first q)
    case ms of
        Nothing -> return Nothing
        Just someS@(SomeSleeper s) -> do
            !my <- readIORef (_next s)
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
                            -- the Suspend.
                            -- if someone beat us to it, try dequeuing again.
                            oldDone <-
                                atomicModifyIORef'
                                    doneRef
                                    (\oldDone ->
                                          (True, oldDone))
                            if oldDone
                                then do
                                    -- we did *not* win the race; try again
                                    dequeue
                                        q
                                else do
                                    -- we won! done.
                                    return
                                        (Just someS)
                        else do
                            -- we did *not* win the race; try again
                            dequeue
                                q

{-# INLINE atomicReadIORef #-}

atomicReadIORef :: IORef a -> IO a
atomicReadIORef !ref =
    atomicModifyIORef'
        ref
        (\oldVal ->
              (oldVal, oldVal))

-- TODO: Consider (carefully) using pointer equality instead of maintaining a
-- unique ID.
eqSleeper
    :: Sleeper a -> Sleeper b -> Bool
eqSleeper !s1 !s2 = _sid s1 == _sid s2

dequeueSleeper :: WaitQ -> SomeSleeper -> IO ()
dequeueSleeper !q someS@(SomeSleeper s) = do
    !mx <- readIORef (_prev s)
    !my <- readIORef (_next s)
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
                    !mfirst <- readIORef (_first q)
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
    !ms <- readIORef (_first q)
    case ms of
        Just s -> sleeperChain s
        _      -> return []

sleeperChain :: SomeSleeper -> IO [SomeSleeper]
sleeperChain someS@(SomeSleeper s) = do
    !mnext <- readIORef (_next s)
    case mnext of
        Just next -> do
            ss <- sleeperChain next
            return (someS : ss)
        _ -> return [someS]

printWaitQ :: WaitQ -> IO ()
printWaitQ q = do
    ss <- waitqToList q
    let !chain =
            intercalate
                "->"
                (map
                     (\(SomeSleeper s) ->
                           "(SID: " ++ show (_sid s) ++ ", CID: " ++ show (_id (_chan s)) ++ ")")
                     ss)
    putStrLn $ "WAITQ: " ++ chain
