{-----------------------------------------------------------------------------
    reactive-banana-wx
    
    Example:
    Small database with CRUD operations and filtering.
    To keep things simple, the list box is rebuild every time
    that the database is updated. This is perfectly fine for rapid prototyping.
    A more sophisticated approach would use incremental updates.
------------------------------------------------------------------------------}
{-# LANGUAGE ScopedTypeVariables #-} -- allows "forall t. NetworkDescription t"
{-# LANGUAGE RecursiveDo, NoMonomorphismRestriction #-}

import Prelude hiding (lookup)
import Data.List (isPrefixOf)
import Data.Maybe
import Data.Monoid
import qualified Data.Map as Map
import qualified Data.Set as Set

import qualified Graphics.UI.WX as WX
import Graphics.UI.WX hiding (Event)
import Reactive.Banana
import Reactive.Banana.WX

{-----------------------------------------------------------------------------
    Main
------------------------------------------------------------------------------}
main = start $ do
    -- GUI layout
    f           <- frame    [ text := "CRUD Example (Simple)" ]
    listBox     <- singleListBox f []
    createBtn   <- button f [ text := "Create" ]
    deleteBtn   <- button f [ text := "Delete" ]
    filterEntry <- entry f  [ processEnter := True ]
    
    firstname <- entry f  [ processEnter := True ]
    lastname  <- entry f  [ processEnter := True ]
    
    let dataItem = grid 10 10 [[label "First Name:", widget firstname]
                              ,[label "Last Name:" , widget lastname]]
    set f [layout := margin 10 $
            grid 10 5
                [[row 5 [label "Filter prefix:", widget filterEntry], glue]
                ,[minsize (sz 200 300) $ widget listBox, dataItem]
                ,[row 10 [widget createBtn, widget deleteBtn], glue]
                ]]

    -- event network
    let networkDescription :: forall t. NetworkDescription t ()
        networkDescription = mdo
            -- events from buttons
            eCreate <- event0 createBtn command       
            eDelete <- event0 deleteBtn command
            -- filter string
            bFilterString <- behaviorText filterEntry ""
            let bFilter :: Behavior t (String -> Bool)
                bFilter = isPrefixOf <$> bFilterString

            -- list box with selection
            bSelection <- reactiveListDisplay listBox bListItems bShowDataItem

            -- data item display
            (_,eDataItemIn) <- reactiveDataItem (firstname,lastname) bDataItemOut
            
            let -- database
                bDatabase :: Behavior t (Database DataItem)
                bDatabase = accumB emptydb $ mconcat
                    [ create ("Emil","Example") <$ eCreate
                    , filterJust $ update' <$> bSelection <@> eDataItemIn
                    , delete <$> filterJust (bSelection <@ eDelete)
                    ]
                    where
                    update' mkey x = flip update x <$> mkey
                
                bLookup :: Behavior t (DatabaseKey -> Maybe DataItem)
                bLookup = flip lookup <$> bDatabase
                
                bShowDataItem :: Behavior t (DatabaseKey -> String)
                bShowDataItem = (maybe "" showDataItem .) <$> bLookup
                
                bListItems :: Behavior t [DatabaseKey]
                bListItems = (\p show -> filter (p. show) . keys)
                    <$> bFilter <*> bShowDataItem <*> bDatabase

                bDataItemOut :: Behavior t (Maybe DataItem)
                bDataItemOut = (=<<) <$> bLookup <*> bSelection

            -- TODO: Delete event must change selection!

            -- automatically enable / disable editing
            let
                bDisplayItem :: Behavior t Bool
                bDisplayItem = maybe False (const True) <$> bSelection
            sink deleteBtn [ enabled :== bDisplayItem ]
            sink firstname [ enabled :== bDisplayItem ]
            sink lastname  [ enabled :== bDisplayItem ]
    
    network <- compile networkDescription    
    actuate network

{-----------------------------------------------------------------------------
    Database Model
------------------------------------------------------------------------------}
type DatabaseKey = Int
data Database a  = Database { nextKey :: !Int, db :: Map.Map DatabaseKey a }

emptydb = Database 0 Map.empty
keys    = Map.keys . db

create x     (Database newkey db) = Database (newkey+1) $ Map.insert newkey x db
update key x (Database newkey db) = Database newkey     $ Map.insert key    x db
delete key   (Database newkey db) = Database newkey     $ Map.delete key db
lookup key   (Database _      db) = Map.lookup key db

{-----------------------------------------------------------------------------
    Data items that are stored in the data base
------------------------------------------------------------------------------}
type DataItem = (String, String)
showDataItem (firstname, lastname) = lastname ++ ", " ++ firstname

{- Note: On breaking feedback loops.

The right abstraction for this is a  behavior + notifications .
The point is that the notifications do *not* represent every single change
in the behavior. Instead, they represent selected changes.
That's why the applicative instance for this data type is a bit different
than usual.

-}

-- text entry widgets in terms of discrete time-varying values
reactiveTextEntry
    :: TextCtrl a
    -> Behavior t String      -- set text programmatically (view)
    -> NetworkDescription t
        (Behavior t String    -- current text (both view & controller)
        ,Event t String)      -- user changes (controller)
reactiveTextEntry entry input = do
    sink entry [ text :== input ]               -- display value

    eUser <- changes =<< behaviorText entry ""  -- user changes
    eIn   <- changes input                      -- input changes
    x     <- initial input
    -- programmatic changes will affect the text box *after* user changes.
    return (stepper x (eUser `union` eIn), eUser)

-- whole data item (consisting of two text entries)
reactiveDataItem
    :: (TextCtrl a, TextCtrl b)
    -> Behavior t (Maybe DataItem)
    -> NetworkDescription t
        (Behavior t DataItem, Event t DataItem)
reactiveDataItem (firstname,lastname) input = do
    (b1,e1) <- reactiveTextEntry firstname (fst . maybe ("","") id <$> input)
    (b2,e2) <- reactiveTextEntry lastname  (snd . maybe ("","") id <$> input)
    return ( (,) <$> b1 <*> b2 ,
        ((,) <$> b1 <@> e2) `union` (flip (,) <$> b2 <@> e1))


{-----------------------------------------------------------------------------
    reactive list display
    
    Display a list of (distinct) items in a list box.
    The current selection contains one or no items.
    Changing the set may unselect the current item,
        but will not change it to another item.
------------------------------------------------------------------------------}
reactiveListDisplay :: forall t a b. Ord a
    => SingleListBox b          -- ListBox widget to use
    -> Behavior t [a]           -- list of items
    -> Behavior t (a -> String) -- display an item
    -> NetworkDescription t
        (Behavior t (Maybe a))  -- current selection as item (possibly empty)
reactiveListDisplay listBox elements display = do
    -- retrieve selection index
    bSelection <- behaviorListBoxSelection listBox

    -- display items
    sink listBox [ items :== map <$> display <*> elements ]
    -- changing the display won't change the current selection
    eDisplay <- changes display
    sink listBox [ selection :== stepper (-1) $ bSelection <@ eDisplay ]

    -- return current selection as element
    let bIndexed :: Behavior t (Map.Map Int a)
        bIndexed = Map.fromList . zip [0..] <$> elements
    return $ Map.lookup <$> bSelection <*> bIndexed



{-----------------------------------------------------------------------------
    wxHaskell convenience wrappers and bug fixes
------------------------------------------------------------------------------}
-- | Return *user* changes to the list box selection.
behaviorListBoxSelection :: SingleListBox b -> NetworkDescription t (Behavior t Int)
behaviorListBoxSelection listBox = do
    liftIO $ fixSelectionEvent listBox
    a <- liftIO $ event1ToAddHandler listBox (event0ToEvent1 select)
    fromChanges (-1) $ mapIO (const $ get listBox selection) a

-- Fix @select@ event not being fired when items are *un*selected.
fixSelectionEvent listbox =
    liftIO $ set listbox [ on unclick := handler ]
    where
    handler _ = do
        propagateEvent
        s <- get listbox selection
        when (s == -1) $ (get listbox (on select)) >>= id
