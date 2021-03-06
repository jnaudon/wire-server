{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators     #-}

module Galley.API.Teams
    ( createTeam
    , updateTeam
    , getTeam
    , getManyTeams
    , deleteTeam
    , addTeamMember
    , getTeamMembers
    , getTeamMember
    , deleteTeamMember
    , getTeamConversations
    , getTeamConversation
    , deleteTeamConversation
    , updateTeamMember
    ) where

import Cassandra (result, hasMore)
import Control.Lens
import Control.Monad (unless, when, void)
import Control.Monad.Catch
import Control.Monad.IO.Class
import Data.ByteString.Conversion
import Data.Foldable (for_, foldrM)
import Data.Int
import Data.Id
import Data.List1 (list1)
import Data.Maybe (catMaybes, isJust)
import Data.Range
import Data.Time.Clock (getCurrentTime)
import Data.Traversable (mapM)
import Galley.App
import Galley.API.Error
import Galley.API.Util
import Galley.Intra.Push
import Galley.Types.Teams
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Predicate hiding (setStatus, result)
import Network.Wai.Utilities
import Prelude hiding (head, mapM)

import qualified Data.Set as Set
import qualified Galley.Data as Data
import qualified Galley.Types as Conv
import qualified Galley.Types.Teams as Teams
import qualified Galley.Data.Types as Data

getTeam :: UserId ::: TeamId ::: JSON -> Galley Response
getTeam (zusr::: tid ::: _) =
    maybe (throwM teamNotFound) (pure . json) =<< lookupTeam zusr tid

getManyTeams :: UserId ::: Maybe (Either (Range 1 32 (List TeamId)) TeamId) ::: Range 1 100 Int32 ::: JSON -> Galley Response
getManyTeams (zusr ::: range ::: size ::: _) =
    withTeamIds zusr range size $ \more ids -> do
        teams <- mapM (lookupTeam zusr) ids
        pure (json $ newTeamList (catMaybes teams) more)

lookupTeam :: UserId -> TeamId -> Galley (Maybe Team)
lookupTeam zusr tid = do
    tm <- Data.teamMember tid zusr
    if isJust tm then
        fmap Data.tdTeam <$> Data.team tid
    else
        pure Nothing

createTeam :: UserId ::: ConnId ::: Request ::: JSON ::: JSON -> Galley Response
createTeam (zusr::: zcon ::: req ::: _) = do
    body <- fromBody req invalidPayload
    team <- Data.createTeam zusr (body^.newTeamName) (body^.newTeamIcon) (body^.newTeamIconKey)
    let owner  = newTeamMember zusr fullPermissions
    let others = filter ((zusr /=) . view userId)
               . maybe [] fromRange
               $ body^.newTeamMembers
    ensureConnected zusr (map (view userId) others)
    for_ (owner : others) $
        Data.addTeamMember (team^.teamId)
    now <- liftIO getCurrentTime
    let e = newEvent TeamCreate (team^.teamId) now & eventData .~ Just (EdTeamCreate team)
    let r = membersToRecipients Nothing others
    push1 $ newPush1 zusr (TeamEvent e) (list1 (userRecipient zusr) r) & pushConn .~ Just zcon
    pure (empty & setStatus status201 . location (team^.teamId))

updateTeam :: UserId ::: ConnId ::: TeamId ::: Request ::: JSON ::: JSON -> Galley Response
updateTeam (zusr::: zcon ::: tid ::: req ::: _) = do
    body <- fromBody req invalidPayload
    membs <- Data.teamMembers tid
    void $ permissionCheck zusr SetTeamData membs
    Data.updateTeam tid body
    now <- liftIO getCurrentTime
    let e = newEvent TeamUpdate tid now & eventData .~ Just (EdTeamUpdate body)
    let r = list1 (userRecipient zusr) (membersToRecipients (Just zusr) membs)
    push1 $ newPush1 zusr (TeamEvent e) r & pushConn .~ Just zcon
    pure empty

deleteTeam :: UserId ::: ConnId ::: TeamId ::: JSON -> Galley Response
deleteTeam (zusr::: zcon ::: tid ::: _) = do
    alive <- Data.isTeamAlive tid
    membs <- Data.teamMembers tid
    when alive $
        void $ permissionCheck zusr DeleteTeam membs
    now    <- liftIO getCurrentTime
    convs  <- filter (not . view managedConversation) <$> Data.teamConversations tid
    events <- foldrM (pushEvents now membs) [] convs
    let e = newEvent TeamDelete tid now
    let r = list1 (userRecipient zusr) (membersToRecipients (Just zusr) membs)
    pushSome ((newPush1 zusr (TeamEvent e) r & pushConn .~ Just zcon) : events)
    Data.deleteTeam tid
    pure empty
  where
    pushEvents now membs c pp = do
        mm <- flip nonTeamMembers membs <$> Data.members (c^.conversationId)
        let e = Conv.Event Conv.ConvDelete (c^.conversationId) zusr now Nothing
        let p = newPush zusr (ConvEvent e) (map recipient mm)
        pure (maybe pp (\x -> (x & pushConn .~ Just zcon) : pp) p)

getTeamMembers :: UserId ::: TeamId ::: JSON -> Galley Response
getTeamMembers (zusr::: tid ::: _) = do
    mems <- Data.teamMembers tid
    case findTeamMember zusr mems of
        Nothing -> throwM noTeamMember
        Just  m -> do
            let withPerm = m `hasPermission` GetMemberPermissions
            pure (json $ teamMemberListJson withPerm (newTeamMemberList mems))

getTeamMember :: UserId ::: TeamId ::: UserId ::: JSON -> Galley Response
getTeamMember (zusr::: tid ::: uid ::: _) = do
    mems <- Data.teamMembers tid
    case findTeamMember zusr mems of
        Nothing -> throwM noTeamMember
        Just  m -> do
            let withPerm = m `hasPermission` GetMemberPermissions
            let member   = findTeamMember uid mems
            maybe (throwM teamMemberNotFound) (pure . json . teamMemberJson withPerm) member

addTeamMember :: UserId ::: ConnId ::: TeamId ::: Request ::: JSON ::: JSON -> Galley Response
addTeamMember (zusr::: zcon ::: tid ::: req ::: _) = do
    body <- fromBody req invalidPayload
    mems <- Data.teamMembers tid
    tmem <- permissionCheck zusr AddTeamMember mems
    unless ((body^.ntmNewTeamMember.permissions.self) `Set.isSubsetOf` (tmem^.permissions.copy)) $
        throwM invalidPermissions
    unless (length mems < 128) $
        throwM tooManyTeamMembers
    ensureConnected zusr [body^.ntmNewTeamMember.userId]
    Data.addTeamMember tid (body^.ntmNewTeamMember)
    cc <- filter (view managedConversation) <$> Data.teamConversations tid
    for_ cc $ \c ->
        Data.addMember (c^.conversationId) (body^.ntmNewTeamMember.userId)
    now <- liftIO getCurrentTime
    let e = newEvent MemberJoin tid now & eventData .~ Just (EdMemberJoin (body^.ntmNewTeamMember.userId))
    let r = list1 (userRecipient zusr) (membersToRecipients (Just zusr) ((body^.ntmNewTeamMember) : mems))
    push1 $ newPush1 zusr (TeamEvent e) r & pushConn .~ Just zcon
    pure empty

updateTeamMember :: UserId ::: ConnId ::: TeamId ::: Request ::: JSON ::: JSON -> Galley Response
updateTeamMember (zusr::: zcon ::: tid ::: req ::: _) = do
    body <- fromBody req invalidPayload
    let user = body^.ntmNewTeamMember.userId
    let perm = body^.ntmNewTeamMember.permissions
    members <- Data.teamMembers tid
    member  <- permissionCheck zusr SetMemberPermissions members
    unless ((perm^.self) `Set.isSubsetOf` (member^.permissions.copy)) $
        throwM invalidPermissions
    unless (isTeamMember user members) $
        throwM teamMemberNotFound
    Data.updateTeamMember tid user perm
    now <- liftIO getCurrentTime
    let e = newEvent MemberUpdate tid now & eventData .~ Just (EdMemberUpdate user)
    let r = list1 (userRecipient zusr) (membersToRecipients (Just zusr) members)
    push1 $ newPush1 zusr (TeamEvent e) r & pushConn .~ Just zcon
    pure empty

deleteTeamMember :: UserId ::: ConnId ::: TeamId ::: UserId ::: JSON -> Galley Response
deleteTeamMember (zusr::: zcon ::: tid ::: remove ::: _) = do
    mems <- Data.teamMembers tid
    void $ permissionCheck zusr RemoveTeamMember mems
    now <- liftIO getCurrentTime
    let e = newEvent MemberLeave tid now & eventData .~ Just (EdMemberLeave remove)
    let r = list1 (userRecipient zusr) (membersToRecipients (Just zusr) mems)
    push1 $ newPush1 zusr (TeamEvent e) r & pushConn .~ Just zcon
    Data.removeTeamMember tid remove
    cc <- Data.teamConversations tid
    for_ cc $
        Data.removeMember remove . view conversationId
    pure empty

getTeamConversations :: UserId ::: TeamId ::: JSON -> Galley Response
getTeamConversations (zusr::: tid ::: _) = do
    tm <- Data.teamMember tid zusr >>= ifNothing noTeamMember
    unless (tm `hasPermission` GetTeamConversations) $
        throwM (operationDenied GetTeamConversations)
    json . newTeamConversationList <$> Data.teamConversations tid

getTeamConversation :: UserId ::: TeamId ::: ConvId ::: JSON -> Galley Response
getTeamConversation (zusr::: tid ::: cid ::: _) = do
    tm <- Data.teamMember tid zusr >>= ifNothing noTeamMember
    unless (tm `hasPermission` GetTeamConversations) $
        throwM (operationDenied GetTeamConversations)
    Data.teamConversation tid cid >>= maybe (throwM convNotFound) (pure . json)

deleteTeamConversation :: UserId ::: ConnId ::: TeamId ::: ConvId ::: JSON -> Galley Response
deleteTeamConversation (zusr::: zcon ::: tid ::: cid ::: _) = do
    tmems <- Data.teamMembers tid
    void $ permissionCheck zusr DeleteConversation tmems
    cmems <- Data.members cid
    now <- liftIO getCurrentTime
    let te = newEvent Teams.ConvDelete tid now & eventData .~ Just (Teams.EdConvDelete cid)
    let ce = Conv.Event Conv.ConvDelete cid zusr now Nothing
    let tr = list1 (userRecipient zusr) (membersToRecipients (Just zusr) tmems)
    let p  = newPush1 zusr (TeamEvent te) tr & pushConn .~ Just zcon
    case map recipient (nonTeamMembers cmems tmems) of
        []     -> push1 p
        (m:mm) -> pushSome [p, newPush1 zusr (ConvEvent ce) (list1 m mm) & pushConn .~ Just zcon]
    Data.removeTeamConv tid cid
    pure empty

-- Internal -----------------------------------------------------------------

-- | Invoke the given continuation 'k' with a list of team IDs
-- which are looked up based on:
--
-- * just limited by size
-- * an (exclusive) starting point (team ID) and size
-- * a list of team IDs
--
-- The last case returns those team IDs which have an associated
-- user. Additionally 'k' is passed in a 'hasMore' indication (which is
-- always false if the third lookup-case is used).
withTeamIds :: UserId
            -> Maybe (Either (Range 1 32 (List TeamId)) TeamId)
            -> Range 1 100 Int32
            -> (Bool -> [TeamId] -> Galley Response)
            -> Galley Response
withTeamIds usr range size k = case range of
    Nothing        -> do
        Data.ResultSet r <- Data.teamIdsFrom usr Nothing (rcast size)
        k (hasMore r) (result r)

    Just (Right c) -> do
        Data.ResultSet r <- Data.teamIdsFrom usr (Just c) (rcast size)
        k (hasMore r) (result r)

    Just (Left cc) -> do
        ids <- Data.teamIdsOf usr cc
        k False ids
{-# INLINE withTeamIds #-}

membersToRecipients :: Maybe UserId -> [TeamMember] -> [Recipient]
membersToRecipients Nothing  = map (userRecipient . view userId)
membersToRecipients (Just u) = map userRecipient . filter (/= u) . map (view userId)

