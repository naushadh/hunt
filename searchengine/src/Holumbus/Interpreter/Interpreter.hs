{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-} 
{-# LANGUAGE TypeFamilies               #-}
module Holumbus.Interpreter.Interpreter where

import           Control.Applicative
import           Control.Concurrent.MVar
import           Control.Monad.Error
import           Control.Monad.Reader

import qualified Data.Binary                       as Bin
import qualified Data.List                         as L
import qualified Data.Map                          as M
import           Data.Set                          (Set)
import qualified Data.Set                          as S
import           Data.Text                         (Text)
import qualified Data.Text                         as T


import           Holumbus.Common.ApiDocument       as ApiDoc
import           Holumbus.Common.BasicTypes
import qualified Holumbus.Common.DocIdMap          as DM
import           Holumbus.Common.Document          (Document)
import           Holumbus.Common.Occurrences       (Occurrences)

import           Holumbus.Analyzer.Analyzer

import           Holumbus.Indexer.TextIndexer      (ContextTextIndexer, TextIndexerCon)
import qualified Holumbus.Indexer.TextIndexer      as Ixx

import           Holumbus.Index.InvertedIndex
import           Holumbus.Index.Proxy.ContextIndex (ContextIndex)
import qualified Holumbus.Index.Proxy.ContextIndex as CIx

import           Holumbus.Query.Fuzzy
import           Holumbus.Query.Language.Grammar
--import           Holumbus.Query.Language.Parser
import           Holumbus.Query.Processor
import           Holumbus.Query.Result             as QRes

import qualified Holumbus.DocTable.DocTable        as Dt
import           Holumbus.DocTable.HashedDocuments as HDt

import           Holumbus.Interpreter.Command

-- ----------------------------------------------------------------------------
--
-- the semantic domains (datatypes for interpretation)
--
-- Env, Index, ...

-- ----------------------------------------------------------------------------
--
-- the indexer used in the interpreter
-- this should be a generic interpreter in the end
-- but right now its okay to have the indexer
-- replaceable by a type declaration



type IpIndexer      ix dt = ContextTextIndexer ix dt

emptyIndexer    :: IpIndexer InvertedIndex (Documents Document)
emptyIndexer    = (CIx.empty, HDt.empty)

-- ----------------------------------------------------------------------------

data Options = Options

emptyOptions :: Options
emptyOptions = Options

-- ----------------------------------------------------------------------------
--
-- the environment
-- with a MVar for storing the index
-- so the MVar acts as a global state (within IO)

data Env ix dt = Env
    { evIndexer :: TextIndexerCon ix dt => MVar (IpIndexer ix dt)
    , evOptions :: Options
    }

initEnv :: TextIndexerCon ix dt => IpIndexer ix dt -> Options -> IO (Env ix dt)
initEnv ixx opt
    = do ixref <- newMVar ixx
         return $ Env ixref opt

-- ----------------------------------------------------------------------------
-- the command evaluation monad
-- ----------------------------------------------------------------------------
newtype CMT ix dt m a = CMT { runCMT :: ReaderT (Env ix dt) (ErrorT CmdError m) a }
  deriving (Applicative, Monad, MonadIO, Functor, MonadReader (Env ix dt), MonadError CmdError)

instance MonadTrans (CMT ix dt) where
  lift = CMT . lift . lift

type CM ix dt = CMT ix dt IO

-- ----------------------------------------------------------------------------

runCM :: TextIndexerCon ix dt => CMT ix dt m a -> Env ix dt -> m (Either CmdError a)
runCM env = runErrorT . runReaderT (runCMT $ env)

runCmd :: TextIndexerCon ix dt => Env ix dt -> Command -> IO (Either CmdError CmdResult)
runCmd env cmd
    = runErrorT . runReaderT (runCMT . execCmd $ cmd) $ env

askIx :: TextIndexerCon ix dt => CM ix dt (IpIndexer ix dt)
askIx
    = do ref <- asks evIndexer
         liftIO $ readMVar ref

-- FIXME: io exception-safe?
modIx :: TextIndexerCon ix dt 
      => (IpIndexer ix dt-> CM ix dt (IpIndexer ix dt, a)) -> CM ix dt a
modIx f
    = do ref <- asks evIndexer
         ix <- liftIO $ takeMVar ref
         (i',a) <- f ix `catchError` putBack ref ix
         liftIO $ putMVar ref i'
         return a
    where
    putBack ref i e = do
        liftIO $ putMVar ref i
        throwError e

modIx_ :: TextIndexerCon ix dt => (IpIndexer ix dt -> CM ix dt (IpIndexer ix dt)) -> CM ix dt ()
modIx_ f = modIx f'
    where f' i = f i >>= \r -> return (r, ())

withIx :: TextIndexerCon ix dt => (IpIndexer ix dt -> CM ix dt a) -> CM ix dt a
withIx f
    = askIx >>= f

askOpts :: TextIndexerCon ix dt => CM ix dt Options
askOpts
    = asks evOptions

throwResError :: TextIndexerCon ix dt => Int -> Text -> CM ix dt a
throwResError n msg
    = throwError $ ResError n msg

throwNYI :: TextIndexerCon ix dt => String -> CM ix dt a
throwNYI c = throwResError 501 $ "command not yet implemented: " `T.append` (T.pack c)

-- ----------------------------------------------------------------------------

-- optimize a command/command sequence
-- delete and batchDelete are both part of the Command datatype, but only BatchDelete should be
-- present for execution
-- an intermediary type may be necessary to ensure that on type-level, e.g.
--   optimizeCmd :: Command -> ExecCommand  &&  execCmd :: ExecCommand -> CM CmdResult
optimizeCmd :: Command -> Command
optimizeCmd (Sequence cs) = Sequence $ opt cs
  where
  opt :: [Command] -> [Command]
  opt cs' = concatMap optGroup $ L.groupBy equalHeads cs'
  -- requires the commands to be grouped by constructor
  optGroup :: [Command] -> [Command]
  -- groups of delete to BatchDelete
  optGroup cs'@(Delete{}:_)
    = foldl (\(BatchDelete us) (Delete u) -> BatchDelete (S.insert u us)) (BatchDelete S.empty) cs' : []
  -- optimize nested sequences too
  -- XXX: maybe flatten sequences
  optGroup cs'@(Sequence{}:_)
    = map optimizeCmd cs'
  optGroup cs' = cs'
  -- group by constructor
  -- NOTE: just delete and sequence because that are the only optimizations for now
  equalHeads :: Command -> Command -> Bool
  equalHeads Delete{}   Delete{}   = True
  equalHeads Sequence{} Sequence{} = True
  equalHeads _ _                   = False
-- a single Delete is not allowed
optimizeCmd (Delete u) = (BatchDelete $ S.singleton u)
optimizeCmd c = c


execCmd :: (Bin.Binary dt) => TextIndexerCon ix dt => Command -> CM ix dt CmdResult
execCmd = execCmd' . optimizeCmd

execCmd' :: (Bin.Binary dt, TextIndexerCon ix dt) => Command -> CM ix dt CmdResult
execCmd' (Search q offset mx)
    = withIx $ execSearch' (wrapSearch offset mx) q

execCmd' (Completion q)
    = withIx $ execSearch' wrapCompletion q

execCmd' (Sequence cs)
    = execSequence cs

execCmd' NOOP
    = return ResOK  -- keep alive test

execCmd' (Insert doc opts)
    = modIx $ execInsert doc opts

execCmd' (Delete _uri)
    = error "execCmd' (Delete{})" --modIx $ execDelete uri

execCmd' (BatchDelete uris)
    = modIx $ execBatchDelete uris

execCmd' (StoreIx filename)
    = withIx $ execStore filename

execCmd' (LoadIx filename)
    = modIx $ \_ix -> execLoad filename

execCmd' (InsertContext cx)
    = modIx $ execInsertContext cx

execCmd' (DeleteContext cx)
    = modIx $ execDeleteContext cx

-- ----------------------------------------------------------------------------

execSequence :: TextIndexerCon ix dt => [Command] -> CM ix dt CmdResult
execSequence []       = execCmd NOOP
execSequence [c]      = execCmd c
execSequence (c : cs) = execCmd c >> execSequence cs


execInsertContext :: TextIndexerCon ix dt 
                  => Context 
                  -> IpIndexer ix dt
                  -> CM ix dt (IpIndexer ix dt, CmdResult)
execInsertContext cx (ix,dt) = return ((CIx.insertContext cx ix,dt), ResOK)  
 
execDeleteContext :: TextIndexerCon ix dt
                  => Context
                  -> IpIndexer ix dt
                  -> CM ix dt (IpIndexer ix dt, CmdResult)
execDeleteContext cx (ix,dt) = return ((CIx.deleteContext cx ix,dt), ResOK)

execInsert :: TextIndexerCon ix dt 
           => ApiDocument -> InsertOption -> IpIndexer ix dt -> CM ix dt (IpIndexer ix dt, CmdResult)
execInsert doc op ixx = do
    --split <- asks (opSplitter . evOptions)
    let split = toDocAndWords
    let (docs, ws) = split doc
    ix'        <- lift $ Ixx.insert docs ws ixx
    case op of
        New     -> return (ix', ResOK) -- TODO: not the real deal yet
        x       -> throwNYI $ show x


execSearch' :: TextIndexerCon ix dt 
            => (Result Document -> CmdResult)
            -> Query
            -> IpIndexer ix dt
            -> CM ix dt CmdResult
execSearch' f q (ix, dt)
    = runQueryM ix dt q >>= return . f 

wrapSearch :: Int -> Int -> Result Document -> CmdResult
wrapSearch offset mx
    = ResSearch
      . mkLimitedResult offset mx
      . map (\(_, (DocInfo d _, _)) -> d)
      . DM.toList .  docHits

wrapCompletion :: Result e -> CmdResult
wrapCompletion
    = ResCompletion
      . map fst -- delete line to get the number of occurrences
      . map (\(c, (_, o)) -> (c, M.foldr (\m r -> r + DM.size m) 0 o))
      . M.toList
      . wordHits


execBatchDelete :: TextIndexerCon ix dt => Set URI -> IpIndexer ix dt -> CM ix dt (IpIndexer ix dt, CmdResult)
execBatchDelete d ix = do
    ix' <- lift $ Ixx.deleteDocsByURI d ix
    return (ix', ResOK)


execStore :: (Bin.Binary a, TextIndexerCon ix dt) =>
             FilePath -> a -> CM ix dt CmdResult
execStore filename x = do
    liftIO $ Bin.encodeFile filename x
    return ResOK


execLoad :: (Bin.Binary a, TextIndexerCon ix dt) =>
             FilePath -> CM ix dt (a, CmdResult)
execLoad filename = do
    x <- liftIO $ Bin.decodeFile filename
    return (x, ResOK)

-- ----------------------------------------------------------------------------

queryConfig     :: ProcessConfig
queryConfig     = ProcessConfig (FuzzyConfig True True 1.0 germanReplacements) True 100 500

runQueryM       :: TextIndexerCon ix dt
                => ContextIndex ix Occurrences
                -> dt
                -> Query
                -> CM ix dt (QRes.Result (Dt.DValue (Documents Document)))
runQueryM       = processQueryM queryConfig
