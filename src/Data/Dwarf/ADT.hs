{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Data.Dwarf.ADT
  ( parseCU
  , Boxed(..)
  , CompilationUnit(..)
  , Decl(..)
  , Def(..)
  , TypeRef(..)
  , BaseType(..)
  , Typedef(..)
  , PtrType(..)
  , ConstType(..)
  , Member(..), StructureType(..), UnionType(..)
  , SubrangeType(..), ArrayType(..)
  , EnumerationType(..), Enumerator(..)
  , SubroutineType(..), FormalParameter(..)
  , Subprogram(..)
  , Variable(..)
  ) where

-- TODO: Separate ADT for type definitions, sum that with
-- subprogram/variable to get a CompilationUnitDef

import Control.Applicative (Applicative(..), (<$>))
import Control.Monad.Fix (MonadFix, mfix)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (Reader, runReader)
import Control.Monad.Trans.State (StateT, evalStateT)
import Data.Dwarf (DieID, DIEMap, DIE(..), DW_TAG(..), DW_AT(..), DW_ATVAL(..), (!?))
import Data.Int (Int64)
import Data.List (intercalate)
import Data.Map (Map)
import Data.Maybe (fromMaybe, maybeToList)
import Data.Traversable (traverse)
import Data.Word (Word, Word64)
import qualified Control.Monad.Trans.Reader as Reader
import qualified Control.Monad.Trans.State as State
import qualified Data.Dwarf as Dwarf
import qualified Data.Dwarf.Lens as Dwarf.Lens
import qualified Data.Map as Map

verifyTag :: DW_TAG -> DIE -> a -> a
verifyTag expected die x
  | tag == expected = x
  | otherwise = error $ "Invalid tag: " ++ show tag
  where
    tag = dieTag die

uniqueAttr :: DW_AT -> DIE -> DW_ATVAL
uniqueAttr at die =
  case die !? at of
  [val] -> val
  [] -> error $ "Missing value for attribute: " ++ show at ++ " in " ++ show die
  xs -> error $ "Multiple values for attribute: " ++ show at ++ ": " ++ show xs ++ " in " ++ show die

maybeAttr :: DW_AT -> DIE -> Maybe DW_ATVAL
maybeAttr at die =
  case die !? at of
  [val] -> Just val
  [] -> Nothing
  xs -> error $ "Multiple values for attribute: " ++ show at ++ ": " ++ show xs ++ " in " ++ show die

getATVal :: DIE -> DW_AT -> Dwarf.Lens.ATVAL_NamedPrism a -> DW_ATVAL -> a
getATVal die at = Dwarf.Lens.getATVal ("attribute " ++ show at ++ " of " ++ show die)

getAttrVal :: DW_AT -> Dwarf.Lens.ATVAL_NamedPrism a -> DIE -> a
getAttrVal at prism die = getATVal die at prism $ uniqueAttr at die

getMAttrVal :: DW_AT -> Dwarf.Lens.ATVAL_NamedPrism a -> DIE -> Maybe a
getMAttrVal at prism die =
  getATVal die at prism <$> maybeAttr at die

getName :: DIE -> String
getName = getAttrVal DW_AT_name Dwarf.Lens.aTVAL_STRING

getMName :: DIE -> Maybe String
getMName = getMAttrVal DW_AT_name Dwarf.Lens.aTVAL_STRING

---------- Monad
newtype M a = M (StateT (Map DieID (Boxed Def)) (Reader DIEMap) a)
  deriving (Functor, Applicative, Monad, MonadFix)
runM :: DIEMap -> M a -> a
runM dieMap (M act) = runReader (evalStateT act Map.empty) dieMap

askDIEMap :: M DIEMap
askDIEMap = liftDefCache $ lift Reader.ask

liftDefCache :: StateT (Map DieID (Boxed Def)) (Reader DIEMap) a -> M a
liftDefCache = M
---------- Monad

cachedMake :: DieID -> M (Boxed Def) -> M (Boxed Def)
cachedMake i act = do
  found <- liftDefCache . State.gets $ Map.lookup i
  case found of
    Just res -> pure res
    Nothing -> mfix $ \res -> do
      liftDefCache . State.modify $ Map.insert i res
      act

parseAt :: DieID -> M (Boxed Def)
parseAt i = cachedMake i $ do
  dieMap <- askDIEMap
  let die = Dwarf.dieRefsDIE $ dieMap Map.! i
  parseDefI die

data Loc = LocOp Dwarf.DW_OP | LocUINT Word64
  deriving (Eq, Ord, Show)

-------------------

data TypeRef = Void | TypeRef (Boxed Def)
  deriving (Eq, Ord)

instance Show TypeRef where
  show Void = "void"
  show (TypeRef _) = "(..type..)"

toTypeRef :: Maybe (Boxed Def) -> TypeRef
toTypeRef Nothing = Void
toTypeRef (Just x) = TypeRef x

-------------------

data Decl = Decl
  { declFile :: Maybe Word64 -- TODO: Convert to FilePath with LNI
  , declLine :: Maybe Int
  , declColumn :: Maybe Int
  } deriving (Eq, Ord)

instance Show Decl where
  show (Decl f l c) = intercalate ":" $ fmap ("FN"++) (toList f) ++ toList l ++ toList c
    where
      toList x = maybeToList $ fmap show x

getDecl :: DIE -> Decl
getDecl die =
  Decl
  (get DW_AT_decl_file)
  (fromIntegral <$> get DW_AT_decl_line)
  (fromIntegral <$> get DW_AT_decl_column)
  where
    get at = getMAttrVal at Dwarf.Lens.aTVAL_UINT die

getByteSize :: DIE -> Word
getByteSize = fromIntegral . getAttrVal DW_AT_byte_size Dwarf.Lens.aTVAL_UINT

getMByteSize :: DIE -> Maybe Word
getMByteSize = fmap fromIntegral . getMAttrVal DW_AT_byte_size Dwarf.Lens.aTVAL_UINT

data Boxed a = Boxed
  { bDieId :: DieID
  , bData :: a
  } deriving (Eq, Ord, Show)

box :: DIE -> a -> Boxed a
box = Boxed . dieId

-- DW_AT_byte_size=(DW_ATVAL_UINT 4)
-- DW_AT_encoding=(DW_ATVAL_UINT 7)
-- DW_AT_name=(DW_ATVAL_STRING "long unsigned int")
data BaseType = BaseType
  { btByteSize :: Word
  , btEncoding :: Dwarf.DW_ATE
  , btName :: Maybe String
  } deriving (Eq, Ord, Show)

parseBaseType :: DIE -> M BaseType
parseBaseType die =
  pure $
  BaseType
  (getByteSize die)
  (Dwarf.dw_ate (getAttrVal DW_AT_encoding Dwarf.Lens.aTVAL_UINT die))
  (getMName die)

-- DW_AT_name=(DW_ATVAL_STRING "ptrdiff_t")
-- DW_AT_decl_file=(DW_ATVAL_UINT 3)
-- DW_AT_decl_line=(DW_ATVAL_UINT 149)
-- DW_AT_type=(DW_ATVAL_REF (DieID 62))}
data Typedef = Typedef
  { tdName :: String
  , tdDecl :: Decl
  , tdType :: TypeRef
  } deriving (Eq, Ord)

instance Show Typedef where
  show (Typedef name decl _) = "Typedef " ++ show name ++ "@(" ++ show decl ++ ") = .."

parseTypeRef :: DIE -> M TypeRef
parseTypeRef die =
  fmap toTypeRef . traverse parseAt $ getMAttrVal DW_AT_type Dwarf.Lens.aTVAL_REF die

parseTypedef :: DIE -> M Typedef
parseTypedef die =
  Typedef (getName die) (getDecl die) <$>
  parseTypeRef die

data PtrType = PtrType
  { ptType :: TypeRef
  , ptByteSize :: Word
  } deriving (Eq, Ord)

instance Show PtrType where
  show (PtrType t _) = "Ptr to " ++ show t

parsePtrType :: DIE -> M PtrType
parsePtrType die =
  PtrType
  <$> parseTypeRef die
  <*> pure (getByteSize die)

-- DW_AT_type=(DW_ATVAL_REF (DieID 104))
data ConstType = ConstType
  { ctType :: TypeRef
  } deriving (Eq, Ord, Show)

parseConstType :: DIE -> M ConstType
parseConstType die =
  ConstType <$> parseTypeRef die

-- DW_AT_name=(DW_ATVAL_STRING "__val")
-- DW_AT_decl_file=(DW_ATVAL_UINT 4)
-- DW_AT_decl_line=(DW_ATVAL_UINT 144)
-- DW_AT_type=(DW_ATVAL_REF (DieID 221))
-- DW_AT_data_member_location=(DW_ATVAL_BLOB "#\NUL")
data Member loc = Member
  { membName :: Maybe String
  , membDecl :: Decl
  , membLoc :: loc
  , membType :: TypeRef
  } deriving (Eq, Ord, Show)

parseMember :: (DIE -> loc) -> DIE -> M (Boxed (Member loc))
parseMember getLoc die =
  box die <$>
  verifyTag DW_TAG_member die .
  Member (getMName die) (getDecl die) (getLoc die) <$>
  parseTypeRef die

-- DW_AT_name=(DW_ATVAL_STRING "__pthread_mutex_s")
-- DW_AT_byte_size=(DW_ATVAL_UINT 24)
-- DW_AT_decl_file=(DW_ATVAL_UINT 6)
-- DW_AT_decl_line=(DW_ATVAL_UINT 79)
data StructureType = StructureType
  { stName :: Maybe String
  , stByteSize :: Maybe Word -- Does not exist for forward-declarations
  , stDecl :: Decl
  , stIsDeclaration :: Bool -- is forward-declaration
  , stMembers :: [Boxed (Member Dwarf.DW_OP)]
  } deriving (Eq, Ord, Show)

parseStructureType :: DIE -> M StructureType
parseStructureType die =
  StructureType (getMName die) (getMByteSize die) (getDecl die)
  (fromMaybe False (getMAttrVal DW_AT_declaration Dwarf.Lens.aTVAL_BOOL die))
  <$> mapM (parseMember getLoc) (dieChildren die)
  where
    getLoc memb =
      Dwarf.parseDW_OP (dieReader memb) $
      getAttrVal DW_AT_data_member_location Dwarf.Lens.aTVAL_BLOB memb
  -- TODO: Parse the member_location, It's a blob with a DWARF program..

-- DW_AT_type=(DW_ATVAL_REF (DieID 101))
-- DW_AT_upper_bound=(DW_ATVAL_UINT 1)
data SubrangeType = SubrangeType
  { subRangeUpperBound :: Word
  , subRangeType :: TypeRef
  } deriving (Eq, Ord, Show)

parseSubrangeType :: DIE -> M (Boxed SubrangeType)
parseSubrangeType die =
  box die <$>
  verifyTag DW_TAG_subrange_type die .
  SubrangeType
  (fromIntegral (getAttrVal DW_AT_upper_bound Dwarf.Lens.aTVAL_UINT die))
  <$> parseTypeRef die

-- DW_AT_type=(DW_ATVAL_REF (DieID 62))
data ArrayType = ArrayType
  { atSubrangeType :: Boxed SubrangeType
  , atType :: TypeRef
  } deriving (Eq, Ord, Show)

parseArrayType :: DIE -> M ArrayType
parseArrayType die =
  ArrayType <$> parseSubrangeType child <*> parseTypeRef die
  where
    child = case dieChildren die of
      [x] -> x
      cs -> error $ "Array must have exactly one child, not: " ++ show cs

----------------

-- DW_AT_byte_size=(DW_ATVAL_UINT 4)
-- DW_AT_decl_file=(DW_ATVAL_UINT 6)
-- DW_AT_decl_line=(DW_ATVAL_UINT 96)
data UnionType = UnionType
  { unionName :: Maybe String
  , unionByteSize :: Word
  , unionDecl :: Decl
  , unionMembers :: [Boxed (Member (Maybe DW_ATVAL))]
  } deriving (Eq, Ord, Show)

parseUnionType :: DIE -> M UnionType
parseUnionType die =
  UnionType (getMName die) (getByteSize die) (getDecl die)
  <$> mapM (parseMember getLoc) (dieChildren die)
  where
    getLoc = maybeAttr DW_AT_data_member_location

-- DW_AT_name=(DW_ATVAL_STRING "_SC_ARG_MAX")
-- DW_AT_const_value=(DW_ATVAL_INT 0)
data Enumerator = Enumerator
  { enumeratorName :: String
  , enumeratorConstValue :: Int64
  } deriving (Eq, Ord, Show)

parseEnumerator :: DIE -> M (Boxed Enumerator)
parseEnumerator die =
  pure . box die . verifyTag DW_TAG_enumerator die $
  Enumerator
  (getName die)
  (getAttrVal DW_AT_const_value Dwarf.Lens.aTVAL_INT die)

-- DW_AT_byte_size=(DW_ATVAL_UINT 4)
-- DW_AT_decl_file=(DW_ATVAL_UINT 11)
-- DW_AT_decl_line=(DW_ATVAL_UINT 74)
data EnumerationType = EnumerationType
  { enumName :: Maybe String
  , enumDecl :: Decl
  , enumByteSize :: Word
  , enumEnumerators :: [Boxed Enumerator]
  } deriving (Eq, Ord, Show)

parseEnumerationType :: DIE -> M EnumerationType
parseEnumerationType die =
  EnumerationType (getMName die) (getDecl die) (getByteSize die)
  <$> mapM parseEnumerator (dieChildren die)

-- DW_AT_type=(DW_ATVAL_REF (DieID 119))
data FormalParameter = FormalParameter
  { formalParamName :: Maybe String
  , formalParamType :: TypeRef
  } deriving (Eq, Ord, Show)

parseFormalParameter :: DIE -> M (Boxed FormalParameter)
parseFormalParameter die =
  box die <$>
  verifyTag DW_TAG_formal_parameter die .
  FormalParameter (getMName die) <$> parseTypeRef die

-- DW_AT_prototyped=(DW_ATVAL_BOOL True)
-- DW_AT_type=(DW_ATVAL_REF (DieID 62))
data SubroutineType = SubroutineType
  { subrPrototyped :: Bool
  , subrRetType :: TypeRef
  , subrFormalParameters :: [Boxed FormalParameter]
  } deriving (Eq, Ord, Show)

getPrototyped :: DIE -> Bool
getPrototyped = fromMaybe False . getMAttrVal DW_AT_prototyped Dwarf.Lens.aTVAL_BOOL

parseSubroutineType :: DIE -> M SubroutineType
parseSubroutineType die =
  SubroutineType (getPrototyped die)
  <$> parseTypeRef die
  <*> mapM parseFormalParameter (dieChildren die)

getLowPC :: DIE -> Word64
getLowPC = getAttrVal DW_AT_low_pc Dwarf.Lens.aTVAL_UINT

getMLowPC :: DIE -> Maybe Word64
getMLowPC = getMAttrVal DW_AT_low_pc Dwarf.Lens.aTVAL_UINT

getMHighPC :: DIE -> Maybe Word64
getMHighPC = getMAttrVal DW_AT_high_pc Dwarf.Lens.aTVAL_UINT

-- DW_AT_name=(DW_ATVAL_STRING "selinux_enabled_check")
-- DW_AT_decl_file=(DW_ATVAL_UINT 1)
-- DW_AT_decl_line=(DW_ATVAL_UINT 133)
-- DW_AT_prototyped=(DW_ATVAL_BOOL True)
-- DW_AT_type=(DW_ATVAL_REF (DieID 62))
-- DW_AT_low_pc=(DW_ATVAL_UINT 135801260)
-- DW_AT_high_pc=(DW_ATVAL_UINT 135801563)
-- DW_AT_frame_base=(DW_ATVAL_UINT 0)
data Subprogram = Subprogram
  { subprogName :: String
  , subprogDecl :: Decl
  , subprogPrototyped :: Bool
  , subprogLowPC :: Maybe Word64
  , subprogHighPC :: Maybe Word64
  , subprogFrameBase :: Maybe Loc
  , subprogFormalParameters :: [Boxed FormalParameter]
  , subprogUnspecifiedParameters :: Bool
  , subprogVariables :: [Boxed (Variable (Maybe String))]
  , subprogType :: TypeRef
  } deriving (Eq, Ord, Show)

data SubprogramChild
  = SubprogramChildFormalParameter (Boxed FormalParameter)
  | SubprogramChildVariable (Boxed (Variable (Maybe String)))
  | SubprogramChildIgnored
  | SubprogramChildUnspecifiedParameters
  deriving (Eq)

parseSubprogram :: DIE -> M Subprogram
parseSubprogram die = do
  children <- mapM parseChild (dieChildren die)
  Subprogram (getName die) (getDecl die) (getPrototyped die)
    (getMLowPC die) (getMHighPC die)
    (parseLoc die <$> maybeAttr DW_AT_frame_base die)
    [x | SubprogramChildFormalParameter x <- children]
    (SubprogramChildUnspecifiedParameters `elem` children)
    [x | SubprogramChildVariable x <- children]
    <$> parseTypeRef die
  where
    parseChild child =
      case dieTag child of
      DW_TAG_formal_parameter ->
        SubprogramChildFormalParameter <$> parseFormalParameter child
      DW_TAG_lexical_block -> pure SubprogramChildIgnored -- TODO: Parse content?
      DW_TAG_label -> pure SubprogramChildIgnored
      DW_TAG_variable -> SubprogramChildVariable . box child  <$> parseVariable getMName child
      DW_TAG_inlined_subroutine -> pure SubprogramChildIgnored
      DW_TAG_user 137 -> pure SubprogramChildIgnored -- GNU extensions, safe to ignore here
      DW_TAG_unspecified_parameters -> pure SubprogramChildUnspecifiedParameters
      tag -> error $ "unsupported child tag for subprogram: " ++ show tag ++ " in: " ++ show die

-- DW_AT_name=(DW_ATVAL_STRING "sfs")
-- DW_AT_decl_file=(DW_ATVAL_UINT 1)
-- DW_AT_decl_line=(DW_ATVAL_UINT 135)
-- DW_AT_type=(DW_ATVAL_REF (DieID 2639))
-- DW_AT_location=(DW_ATVAL_BLOB "\145\168\DEL")
data Variable name = Variable
  { varName :: name
  , varDecl :: Decl
  , varLoc :: Maybe Loc
  , varType :: TypeRef
  } deriving (Eq, Ord, Show)

parseVariable :: (DIE -> a) -> DIE -> M (Variable a)
parseVariable getVarName die =
  Variable (getVarName die) (getDecl die)
  (parseLoc die <$> maybeAttr DW_AT_location die) <$>
  parseTypeRef die
  where

parseLoc :: DIE -> DW_ATVAL -> Loc
parseLoc die (DW_ATVAL_BLOB blob) = LocOp $ Dwarf.parseDW_OP (dieReader die) blob
parseLoc _ (DW_ATVAL_UINT uint) = LocUINT uint
parseLoc _ other =
  error $
  "Expected DW_ATVAL_BLOB or DW_ATVAL_UINT for DW_AT_location field of variable, got: " ++
  show other

data Def
  = DefBaseType BaseType
  | DefTypedef Typedef
  | DefPtrType PtrType
  | DefConstType ConstType
  | DefStructureType StructureType
  | DefArrayType ArrayType
  | DefUnionType UnionType
  | DefEnumerationType EnumerationType
  | DefSubroutineType SubroutineType
  | DefSubprogram Subprogram
  | DefVariable (Variable String)
  deriving (Eq, Ord, Show)

noChildren :: DIE -> DIE
noChildren die@DIE{dieChildren=[]} = die
noChildren die@DIE{dieChildren=cs} = error $ "Unexpected children: " ++ show cs ++ " in " ++ show die

parseDefI :: DIE -> M (Boxed Def)
parseDefI die =
  box die <$>
  case dieTag die of
  DW_TAG_base_type    -> fmap DefBaseType . parseBaseType $ noChildren die
  DW_TAG_typedef      -> fmap DefTypedef . parseTypedef $ noChildren die
  DW_TAG_pointer_type -> fmap DefPtrType . parsePtrType $ noChildren die
  DW_TAG_const_type   -> fmap DefConstType . parseConstType $ noChildren die
  DW_TAG_structure_type -> fmap DefStructureType $ parseStructureType die
  DW_TAG_array_type   -> fmap DefArrayType $ parseArrayType die
  DW_TAG_union_type   -> fmap DefUnionType $ parseUnionType die
  DW_TAG_enumeration_type -> fmap DefEnumerationType $ parseEnumerationType die
  DW_TAG_subroutine_type -> fmap DefSubroutineType $ parseSubroutineType die
  DW_TAG_subprogram   -> fmap DefSubprogram $ parseSubprogram die
  DW_TAG_variable     -> fmap DefVariable $ parseVariable getName die
  _ -> error $ "unsupported: " ++ show die

parseDef :: DIE -> M (Boxed Def)
parseDef die = cachedMake (dieId die) $ parseDefI die

-- DW_AT_producer=(DW_ATVAL_STRING "GNU C 4.4.5")
-- DW_AT_language=(DW_ATVAL_UINT 1)
-- DW_AT_name=(DW_ATVAL_STRING "../src/closures.c")
-- DW_AT_comp_dir=(DW_ATVAL_STRING "/home/ian/zz/ghc-7.4.1/libffi/build/i386-unknown-linux-gnu")
-- DW_AT_low_pc=(DW_ATVAL_UINT 135625548)
-- DW_AT_high_pc=(DW_ATVAL_UINT 135646754)
-- DW_AT_stmt_list=(DW_ATVAL_UINT 0)
data CompilationUnit = CompilationUnit
  { cuProducer :: String
  , cuLanguage :: Dwarf.DW_LANG
  , cuName :: String
  , cuCompDir :: String
  , cuLowPc :: Word64
  , cuHighPc :: Maybe Word64
--  , cuLineNumInfo :: ([String], [Dwarf.DW_LNE])
  , cuDefs :: [Boxed Def]
  } deriving (Show)

parseCU :: DIEMap -> DIE -> Boxed CompilationUnit
parseCU dieMap die =
  runM dieMap $
  box die .
  verifyTag DW_TAG_compile_unit die .
  CompilationUnit
  (getAttrVal DW_AT_producer Dwarf.Lens.aTVAL_STRING die)
  (Dwarf.dw_lang (getAttrVal DW_AT_language Dwarf.Lens.aTVAL_UINT die))
  (getName die)
  (getAttrVal DW_AT_comp_dir Dwarf.Lens.aTVAL_STRING die)
  (getLowPC die) (getMHighPC die)
  -- lineNumInfo
  <$> mapM parseDef (dieChildren die)
