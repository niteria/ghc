%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[Desugar]{@deSugar@: the main function}

\begin{code}
module Desugar ( deSugar, deSugarExpr ) where

#include "HsVersions.h"

import CmdLineOpts	( DynFlag(..), DynFlags(..), dopt, opt_SccProfilingOn )
import HscTypes		( ModGuts(..), ModGuts, HscEnv(..), GhciMode(..),
			  Dependencies(..), TypeEnv, IsBootInterface )
import HsSyn		( RuleDecl(..), RuleBndr(..), HsExpr(..), LHsExpr,
			  HsBindGroup(..), LRuleDecl, HsBind(..) )
import TcRnTypes	( TcGblEnv(..), ImportAvails(..) )
import MkIface		( mkUsageInfo )
import Id		( Id, setIdExported, idName, idIsFrom, isLocalId )
import Name		( Name, isExternalName )
import CoreSyn
import PprCore		( pprIdRules, pprCoreExpr )
import Subst		( SubstResult(..), substExpr, mkSubst, extendIdSubstList )
import DsMonad
import DsExpr		( dsLExpr )
import DsBinds		( dsHsBinds, AutoScc(..) )
import DsForeign	( dsForeigns )
import DsExpr		()	-- Forces DsExpr to be compiled; DsBinds only
				-- depends on DsExpr.hi-boot.
import Module		( Module, moduleEnvElts, delModuleEnv, moduleFS )
import Id		( Id )
import RdrName	 	( GlobalRdrEnv )
import NameSet
import VarEnv
import VarSet
import Bag		( Bag, isEmptyBag, emptyBag, bagToList )
import CoreLint		( showPass, endPass )
import CoreFVs		( ruleRhsFreeVars )
import Packages	  	( PackageState(thPackageId) )
import ErrUtils		( doIfSet, dumpIfSet_dyn, pprBagOfWarnings, 
			  errorsFound, WarnMsg )
import ListSetOps	( insertList )
import Outputable
import UniqSupply	( mkSplitUniqSupply )
import SrcLoc		( Located(..), unLoc )
import DATA_IOREF	( readIORef )
import FastString
import Util		( sortLe )
\end{code}

%************************************************************************
%*									*
%* 		The main function: deSugar
%*									*
%************************************************************************

\begin{code}
deSugar :: HscEnv -> TcGblEnv -> IO (Bag WarnMsg, Maybe ModGuts)
-- Can modify PCS by faulting in more declarations

deSugar hsc_env 
        tcg_env@(TcGblEnv { tcg_mod       = mod,
		    	    tcg_type_env  = type_env,
		    	    tcg_imports   = imports,
		    	    tcg_exports   = exports,
		    	    tcg_dus	  = dus, 
		    	    tcg_inst_uses = dfun_uses_var,
			    tcg_th_used   = th_var,
			    tcg_keep	  = keep_var,
		    	    tcg_rdr_env   = rdr_env,
		    	    tcg_fix_env   = fix_env,
	    	    	    tcg_deprecs   = deprecs,
			    tcg_binds     = binds,
			    tcg_fords     = fords,
			    tcg_rules     = rules,
		    	    tcg_insts     = insts })
  = do	{ showPass dflags "Desugar"

	-- Desugar the program
	; ((all_prs, ds_rules, ds_fords), warns) 
		<- initDs hsc_env mod rdr_env type_env $ do
		{ core_prs <- dsHsBinds auto_scc binds []
		; (ds_fords, foreign_prs) <- dsForeigns fords
		; let all_prs = foreign_prs ++ core_prs
		      local_bndrs = mkVarSet (map fst all_prs)
		; ds_rules <- mappM (dsRule mod local_bndrs) rules
		; return (all_prs, ds_rules, ds_fords) }



	-- If warnings are considered errors, leave.
	; if errorsFound dflags (warns, emptyBag)
	   then return (warns, Nothing)
	   else do

	{ 	-- Add export flags to bindings
	  keep_alive <- readIORef keep_var
	; let final_prs = addExportFlags ghci_mode exports keep_alive 
				   	 all_prs ds_rules
	      ds_binds  = [Rec final_prs]
	-- Notice that we put the whole lot in a big Rec, even the foreign binds
	-- When compiling PrelFloat, which defines data Float = F# Float#
	-- we want F# to be in scope in the foreign marshalling code!
	-- You might think it doesn't matter, but the simplifier brings all top-level
	-- things into the in-scope set before simplifying; so we get no unfolding for F#!

	-- Lint result if necessary
	; endPass dflags "Desugar" Opt_D_dump_ds ds_binds

	-- Dump output
	; doIfSet (dopt Opt_D_dump_ds dflags) 
		  (printDump (ppr_ds_rules ds_rules))

	; dfun_uses <- readIORef dfun_uses_var		-- What dfuns are used
	; th_used   <- readIORef th_var			-- Whether TH is used
	; let used_names = allUses dus `unionNameSets` dfun_uses
	      thPackage = thPackageId (pkgState dflags)
	      pkgs | Just th_id <- thPackage, th_used
		   = insertList th_id  (imp_dep_pkgs imports)
	      	   | otherwise
		   = imp_dep_pkgs imports

	      dep_mods = moduleEnvElts (delModuleEnv (imp_dep_mods imports) mod)
		-- M.hi-boot can be in the imp_dep_mods, but we must remove
		-- it before recording the modules on which this one depends!
		-- (We want to retain M.hi-boot in imp_dep_mods so that 
		--  loadHiBootInterface can see if M's direct imports depend 
		--  on M.hi-boot, and hence that we should do the hi-boot consistency 
		--  check.)

	      dir_imp_mods = imp_mods imports

	; usages <- mkUsageInfo hsc_env dir_imp_mods dep_mods used_names

	; let 
		-- Modules don't compare lexicographically usually, 
		-- but we want them to do so here.
	     le_mod :: Module -> Module -> Bool	 
	     le_mod m1 m2 = moduleFS m1 <= moduleFS m2
	     le_dep_mod :: (Module, IsBootInterface) -> (Module, IsBootInterface) -> Bool	 
	     le_dep_mod (m1,_) (m2,_) = m1 `le_mod` m2

	     deps = Deps { dep_mods  = sortLe le_dep_mod dep_mods,
			   dep_pkgs  = sortLe (<=)   pkgs,	
			   dep_orphs = sortLe le_mod (imp_orphs imports) }
		-- sort to get into canonical order

	     mod_guts = ModGuts {	
		mg_module   = mod,
		mg_exports  = exports,
		mg_deps	    = deps,
		mg_usages   = usages,
		mg_dir_imps = [m | (m,_,_) <- moduleEnvElts dir_imp_mods],
	        mg_rdr_env  = rdr_env,
		mg_fix_env  = fix_env,
		mg_deprecs  = deprecs,
		mg_types    = type_env,
		mg_insts    = insts,
	        mg_rules    = ds_rules,
		mg_binds    = ds_binds,
		mg_foreign  = ds_fords }
	
        ; return (warns, Just mod_guts)
	}}

  where
    dflags       = hsc_dflags hsc_env
    ghci_mode    = hsc_mode hsc_env
    auto_scc | opt_SccProfilingOn = TopLevel
	     | otherwise          = NoSccs

deSugarExpr :: HscEnv
	    -> Module -> GlobalRdrEnv -> TypeEnv 
 	    -> LHsExpr Id
	    -> IO CoreExpr
deSugarExpr hsc_env this_mod rdr_env type_env tc_expr
  = do	{ showPass dflags "Desugar"
	; us <- mkSplitUniqSupply 'd'

	-- Do desugaring
	; (core_expr, ds_warns) <- initDs hsc_env this_mod rdr_env type_env $
				   dsLExpr tc_expr

	-- Display any warnings 
	-- Note: if -Werror is used, we don't signal an error here.
        ; doIfSet (not (isEmptyBag ds_warns))
		  (printErrs (pprBagOfWarnings ds_warns))

	-- Dump output
	; dumpIfSet_dyn dflags Opt_D_dump_ds "Desugared" (pprCoreExpr core_expr)

        ; return core_expr
	}
  where
    dflags       = hsc_dflags hsc_env


--		addExportFlags
-- Set the no-discard flag if either 
--	a) the Id is exported
--	b) it's mentioned in the RHS of an orphan rule
--	c) it's in the keep-alive set
--
-- It means that the binding won't be discarded EVEN if the binding
-- ends up being trivial (v = w) -- the simplifier would usually just 
-- substitute w for v throughout, but we don't apply the substitution to
-- the rules (maybe we should?), so this substitution would make the rule
-- bogus.

-- You might wonder why exported Ids aren't already marked as such;
-- it's just because the type checker is rather busy already and
-- I didn't want to pass in yet another mapping.

addExportFlags ghci_mode exports keep_alive prs rules
  = [(add_export bndr, rhs) | (bndr,rhs) <- prs]
  where
    add_export bndr
	| dont_discard bndr = setIdExported bndr
	| otherwise	    = bndr

    orph_rhs_fvs = unionVarSets [ ruleRhsFreeVars rule
			        | IdCoreRule _ is_orphan_rule rule <- rules, 
				  is_orphan_rule ]
	-- An orphan rule keeps alive the free vars of its right-hand side.  
	-- Non-orphan rules are (later, after gentle simplification) 
	-- attached to the Id and that keeps the rhs free vars alive

    dont_discard bndr = is_exported name
		     || name `elemNameSet` keep_alive
		     || bndr `elemVarSet` orph_rhs_fvs 
		     where
			name = idName bndr

    	-- In interactive mode, we don't want to discard any top-level
    	-- entities at all (eg. do not inline them away during
    	-- simplification), and retain them all in the TypeEnv so they are
    	-- available from the command line.
	--
	-- isExternalName separates the user-defined top-level names from those
	-- introduced by the type checker.
    is_exported :: Name -> Bool
    is_exported | ghci_mode == Interactive = isExternalName
		| otherwise 		   = (`elemNameSet` exports)

ppr_ds_rules [] = empty
ppr_ds_rules rules
  = text "" $$ text "-------------- DESUGARED RULES -----------------" $$
    pprIdRules rules
\end{code}



%************************************************************************
%*									*
%* 		Desugaring transformation rules
%*									*
%************************************************************************

\begin{code}
dsRule :: Module -> IdSet -> LRuleDecl Id -> DsM IdCoreRule
dsRule mod in_scope (L loc (HsRule name act vars lhs rhs))
  = putSrcSpanDs loc $ 
    ds_lhs all_vars lhs		`thenDs` \ (fn, args) ->
    dsLExpr rhs			`thenDs` \ core_rhs ->
    returnDs (IdCoreRule fn (is_orphan fn) (Rule name act tpl_vars args core_rhs))
  where
    tpl_vars  = [var | RuleBndr (L _ var) <- vars]
    all_vars  = mkInScopeSet (extendVarSetList in_scope tpl_vars)
    is_orphan id = not (idIsFrom mod id)
	-- NB we can't use isLocalId in the orphan test, 
	-- because isLocalId isn't true of class methods

ds_lhs all_vars lhs
  = let
	(dict_binds, body) = 
	   case unLoc lhs of
		(HsLet [HsBindGroup dict_binds _ _] body) -> (dict_binds, body)
		other			 	       -> (emptyBag, lhs)
    in
    mappM ds_dict_bind (bagToList dict_binds) 	`thenDs` \ dict_binds' ->
    dsLExpr body				`thenDs` \ body' ->

	-- Substitute the dict bindings eagerly,
	-- and take the body apart into a (f args) form
    let
	subst = extendIdSubstList (mkSubst all_vars) pairs
	pairs = [(id, ContEx subst rhs) | (id,rhs) <- dict_binds']
			-- Note recursion here... substitution won't terminate
			-- if there is genuine recursion... which there isn't
	body'' = substExpr subst body'
    in
	
	-- Now unpack the resulting body
    let
	pair = case collectArgs body'' of
			(Var fn, args) -> (fn, args)
			other	       -> pprPanic "dsRule" (ppr lhs)
    in
    returnDs pair

ds_dict_bind (L _ (VarBind id rhs)) =
  dsLExpr rhs `thenDs` \ rhs' ->
  returnDs (id,rhs')
\end{code}
