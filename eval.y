%{
/************************************************************************/
/*                                                                      */
/*                       CFITSIO Lexical Parser                         */
/*                                                                      */
/* This file is one of 3 files containing code which parses an          */
/* arithmetic expression and evaluates it in the context of an input    */
/* FITS file table extension.  The CFITSIO lexical parser is divided    */
/* into the following 3 parts/files: the CFITSIO "front-end",           */
/* eval_f.c, contains the interface between the user/CFITSIO and the    */
/* real core of the parser; the FLEX interpreter, eval_l.c, takes the   */
/* input string and parses it into tokens and identifies the FITS       */
/* information required to evaluate the expression (ie, keywords and    */
/* columns); and, the BISON grammar and evaluation routines, eval_y.c,  */
/* receives the FLEX output and determines and performs the actual      */
/* operations.  The files eval_l.c and eval_y.c are produced from       */
/* running flex and bison on the files eval.l and eval.y, respectively. */
/* (flex and bison are available from any GNU archive: see www.gnu.org) */
/*                                                                      */
/* The grammar rules, rather than evaluating the expression in situ,    */
/* builds a tree, or Nodal, structure mapping out the order of          */
/* operations and expression dependencies.  This "compilation" process  */
/* allows for much faster processing of multiple rows.  This technique  */
/* was developed by Uwe Lammers of the XMM Science Analysis System,     */
/* although the CFITSIO implementation is entirely code original.       */
/*                                                                      */
/*                                                                      */
/* Modification History:                                                */
/*                                                                      */
/*   Kent Blackburn      c1992  Original parser code developed for the  */
/*                              FTOOLS software package, in particular, */
/*                              the fselect task.                       */
/*   Kent Blackburn      c1995  BIT column support added                */
/*   Peter D Wilson   Feb 1998  Vector column support added             */
/*   Peter D Wilson   May 1998  Ported to CFITSIO library.  User        */
/*                              interface routines written, in essence  */
/*                              making fselect, fcalc, and maketime     */
/*                              capabilities available to all tools     */
/*                              via single function calls.              */
/*   Peter D Wilson   Jun 1998  Major rewrite of parser core, so as to  */
/*                              create a run-time evaluation tree,      */
/*                              inspired by the work of Uwe Lammers,    */
/*                              resulting in a speed increase of        */
/*                              10-100 times.                           */
/*                                                                      */
/************************************************************************/

#define  APPROX 1.0e-7
#include "eval_defs.h"

/***************************************************************/
/*  Replace Bison's BACKUP macro with one that fixes a bug --  */
/*  must update state after popping the stack -- and allows    */
/*  popping multiple terms at one time.                        */
/***************************************************************/

#define YYNEWBACKUP(token, value)                               \
   do								\
     if (yychar == YYEMPTY )   					\
       { yychar = (token);                                      \
         memcpy( &yylval, &(value), sizeof(value) );            \
         yychar1 = YYTRANSLATE (yychar);			\
         while (yylen--) YYPOPSTACK;				\
         yystate = *yyssp;					\
         goto yybackup;						\
       }							\
     else							\
       { yyerror ("syntax error: cannot back up"); YYERROR; }	\
   while (0)

/***************************************************************/
/*  Useful macros for accessing/testing Nodes                  */
/***************************************************************/

#define TEST(a)        if( (a)<0 ) YYERROR
#define SIZE(a)        gParse.Nodes[ a ].value.nelem
#define TYPE(a)        gParse.Nodes[ a ].type
#define PROMOTE(a,b)   if( TYPE(a) > TYPE(b) )                  \
                          b = New_Unary( TYPE(a), 0, b );       \
                       else if( TYPE(a) < TYPE(b) )             \
	                  a = New_Unary( TYPE(b), 0, a );

/*****  Internal functions  *****/

#ifdef __cplusplus
extern "C" {
#endif

static int  Alloc_Node    ( void );
static void Free_Last_Node( void );

static int  New_Const ( int returnType, void *value, long len );
static int  New_Column( int ColNum );
static int  New_Unary ( int returnType, int Op, int Node1 );
static int  New_BinOp ( int returnType, int Node1, int Op, int Node2 );
static int  New_Func  ( int returnType, funcOp Op, int nNodes,
			int Node1, int Node2, int Node3, int Node4, 
			int Node5, int Node6, int Node7 );
static int  New_Deref ( int Var,  int nDim,
			int Dim1, int Dim2, int Dim3, int Dim4, int Dim5 );
static int  Test_Dims ( int Node1, int Node2 );

static void Allocate_Ptrs( Node *this );
static void Do_Unary     ( Node *this );
static void Do_BinOp_bit ( Node *this );
static void Do_BinOp_str ( Node *this );
static void Do_BinOp_log ( Node *this );
static void Do_BinOp_lng ( Node *this );
static void Do_BinOp_dbl ( Node *this );
static void Do_Func      ( Node *this );
static void Do_Deref     ( Node *this );

static char  saobox (double xcen, double ycen, double xwid, double ywid,
		     double rot,  double xcol, double ycol);
static char  ellipse(double xcen, double ycen, double xrad, double yrad,
		     double rot, double xcol, double ycol);
static char  circle (double xcen, double ycen, double rad,
		     double xcol, double ycol);
static char  near   (double x, double y, double tolerance);
static char  bitcmp (char *bitstrm1, char *bitstrm2);
static char  bitlgte(char *bits1, int oper, char *bits2);

static void  bitand(char *result, char *bitstrm1, char *bitstrm2);
static void  bitor (char *result, char *bitstrm1, char *bitstrm2);
static void  bitnot(char *result, char *bits);

static void  yyerror(char *msg);

#ifdef __cplusplus
    }
#endif

%}

%union {
    int    Node;        /* Index of Node */
    double dbl;         /* real value    */
    long   lng;         /* integer value */
    char   log;         /* logical value */
    char   str[256];    /* string value  */
}

%token <log>   BOOLEAN        /* First 3 must be in order of        */
%token <lng>   LONG           /* increasing promotion for later use */
%token <dbl>   DOUBLE
%token <str>   STRING
%token <str>   BITSTR
%token <str>   FUNCTION
%token <str>   BFUNCTION
%token <lng>   COLUMN
%token <lng>   BCOLUMN
%token <lng>   SCOLUMN
%token <lng>   BITCOL
%token <lng>   ROWREF

%type <Node>  expr
%type <Node>  bexpr
%type <Node>  sexpr
%type <Node>  bits

%left     ',' '=' ':'
%left     OR
%left     AND
%left     EQ NE '~'
%left     GT LT LTE GTE
%left     '+' '-' '%'
%left     '*' '/'
%left     '|' '&'
%right    POWER
%left     NOT
%left     INTCAST FLTCAST
%left     UMINUS
%left     '['

%%

lines:   /* nothing ; was | lines line */
       | lines line
       ;

line:           '\n' {}
       | expr   '\n'
                { if( $1<0 ) {
		     yyerror("Couldn't build node structure: out of memory?");
		     YYERROR;  }
		}
       | bexpr  '\n'
                { if( $1<0 ) {
		     yyerror("Couldn't build node structure: out of memory?");
		     YYERROR;  }
		}
       | sexpr  '\n'
                { if( $1<0 ) {
		     yyerror("Couldn't build node structure: out of memory?");
		     YYERROR;  } 
		}
       | bits   '\n'
                { if( $1<0 ) {
		     yyerror("Couldn't build node structure: out of memory?");
		     YYERROR;  }
		}
       | error  '\n' {  yyerrok;  }
       ;

bits:	 BITSTR
                {
                  $$ = New_Const( BITSTR, $1, strlen($1)+1 ); TEST($$);
		  SIZE($$) = strlen($1);
		}
       | BITCOL
                { $$ = New_Column( $1 ); TEST($$); }
       | bits '&' bits
                { $$ = New_BinOp( BITSTR, $1, '&', $3 ); TEST($$);
                  SIZE($$) = ( SIZE($1)>SIZE($3) ? SIZE($1) : SIZE($3) );  }
       | bits '|' bits
                { $$ = New_BinOp( BITSTR, $1, '|', $3 ); TEST($$);
                  SIZE($$) = ( SIZE($1)>SIZE($3) ? SIZE($1) : SIZE($3) );  }
       | bits '+' bits
                { $$ = New_BinOp( BITSTR, $1, '+', $3 ); TEST($$);
                  SIZE($$) = SIZE($1) + SIZE($3);                          }
       | NOT bits
                { $$ = New_Unary( BITSTR, NOT, $2 ); TEST($$);     }
       | '(' bits ')'
                { $$ = $2; }
       ;

expr:    LONG
                { $$ = New_Const( LONG,   &($1), sizeof(long)   ); TEST($$); }
       | DOUBLE
                { $$ = New_Const( DOUBLE, &($1), sizeof(double) ); TEST($$); }
       | COLUMN
                { $$ = New_Column( $1 ); TEST($$); }
       | ROWREF
                { $$ = New_Func( LONG, row_fct, 0, 0, 0, 0, 0, 0, 0, 0 ); }
       | expr '%' expr
                { PROMOTE($1,$3); $$ = New_BinOp( TYPE($1), $1, '%', $3 );
		  TEST($$);                                                }
       | expr '+' expr
                { PROMOTE($1,$3); $$ = New_BinOp( TYPE($1), $1, '+', $3 );
		  TEST($$);                                                }
       | expr '-' expr
                { PROMOTE($1,$3); $$ = New_BinOp( TYPE($1), $1, '-', $3 ); 
		  TEST($$);                                                }
       | expr '*' expr
                { PROMOTE($1,$3); $$ = New_BinOp( TYPE($1), $1, '*', $3 ); 
		  TEST($$);                                                }
       | expr '/' expr
                { PROMOTE($1,$3); $$ = New_BinOp( TYPE($1), $1, '/', $3 ); 
		  TEST($$);                                                }
       | expr POWER expr
                { PROMOTE($1,$3); $$ = New_BinOp( TYPE($1), $1, POWER, $3 );
		  TEST($$);                                                }
       | '-' expr %prec UMINUS
                { $$ = New_Unary( TYPE($2), UMINUS, $2 ); TEST($$); }
       |  '(' expr ')'
                { $$ = $2; }
       | expr '*' bexpr
                { $3 = New_Unary( TYPE($1), 0, $3 );
                  $$ = New_BinOp( TYPE($1), $1, '*', $3 ); 
		  TEST($$);                                }
       | bexpr '*' expr
                { $1 = New_Unary( TYPE($3), 0, $1 );
                  $$ = New_BinOp( TYPE($3), $1, '*', $3 );
                  TEST($$);                                }
       | FUNCTION ')'
                { if (FSTRCMP($1,"RANDOM(") == 0)
                    $$ = New_Func( DOUBLE, rnd_fct, 0, 0, 0, 0, 0, 0, 0, 0 );
                  else
		    {
                     yyerror("Function() not supported");
		     YYERROR;
		    }
                  TEST($$); 
                }
       | FUNCTION bexpr ')'
                { if (FSTRCMP($1,"SUM(") == 0) {
		     $$ = New_Func( LONG, sum_fct, 1, $2, 0, 0, 0, 0, 0, 0 );
                  } else if (FSTRCMP($1,"NELEM(") == 0) {
                     $$ = New_Const( LONG, &( SIZE($2) ), sizeof(long) );
		  } else {
                     yyerror("Function(bool) not supported");
		     YYERROR;
		  }
                  TEST($$); 
		}
       | FUNCTION sexpr ')'
                { if (FSTRCMP($1,"NELEM(") == 0) {
                     $$ = New_Const( LONG, &( SIZE($2) ), sizeof(long) );
		  } else {
                     yyerror("Function(str) not supported");
		     YYERROR;
		  }
                  TEST($$); 
		}
       | FUNCTION bits ')'
                { if (FSTRCMP($1,"NELEM(") == 0) {
                     $$ = New_Const( LONG, &( SIZE($2) ), sizeof(long) );
		  } else {
                     yyerror("Function(bits) not supported");
		     YYERROR;
		  }
                  TEST($$); 
		}
       | FUNCTION expr ')'
                { if (FSTRCMP($1,"SUM(") == 0)
		     $$ = New_Func( TYPE($2), sum_fct, 1, $2,
				    0, 0, 0, 0, 0, 0 );
		  else if (FSTRCMP($1,"NELEM(") == 0)
                     $$ = New_Const( LONG, &( SIZE($2) ), sizeof(long) );
		  else if (FSTRCMP($1,"ABS(") == 0)
		     $$ = New_Func( 0, abs_fct, 1, $2, 0, 0, 0, 0, 0, 0 );
                  else {
		     if( TYPE($2) != DOUBLE ) $2 = New_Unary( DOUBLE, 0, $2 );
                     if (FSTRCMP($1,"SIN(") == 0)
			$$ = New_Func( 0, sin_fct,  1, $2, 0, 0, 0, 0, 0, 0 );
		     else if (FSTRCMP($1,"COS(") == 0)
			$$ = New_Func( 0, cos_fct,  1, $2, 0, 0, 0, 0, 0, 0 );
		     else if (FSTRCMP($1,"TAN(") == 0)
			$$ = New_Func( 0, tan_fct,  1, $2, 0, 0, 0, 0, 0, 0 );
		     else if (FSTRCMP($1,"ARCSIN(") == 0)
			$$ = New_Func( 0, asin_fct, 1, $2, 0, 0, 0, 0, 0, 0 );
		     else if (FSTRCMP($1,"ARCCOS(") == 0)
			$$ = New_Func( 0, acos_fct, 1, $2, 0, 0, 0, 0, 0, 0 );
		     else if (FSTRCMP($1,"ARCTAN(") == 0)
			$$ = New_Func( 0, atan_fct, 1, $2, 0, 0, 0, 0, 0, 0 );
		     else if (FSTRCMP($1,"EXP(") == 0)
			$$ = New_Func( 0, exp_fct,  1, $2, 0, 0, 0, 0, 0, 0 );
		     else if (FSTRCMP($1,"LOG(") == 0)
			$$ = New_Func( 0, log_fct,  1, $2, 0, 0, 0, 0, 0, 0 );
		     else if (FSTRCMP($1,"LOG10(") == 0)
			$$ = New_Func( 0, log10_fct, 1, $2, 0, 0, 0, 0, 0, 0 );
		     else if (FSTRCMP($1,"SQRT(") == 0)
			$$ = New_Func( 0, sqrt_fct, 1, $2, 0, 0, 0, 0, 0, 0 );
		     else {
			yyerror("Function(expr) not supported");
			YYERROR;
		     }
		  }
                  TEST($$); 
                }
       | FUNCTION expr ',' expr ')'
                { 
		   if (FSTRCMP($1,"DEFNULL(") == 0) {
		      if( SIZE($2)>=SIZE($4) && Test_Dims( $2, $4 ) ) {
			 PROMOTE($2,$4);
			 $$ = New_Func( 0, defnull_fct, 2, $2, $4, 0,
					0, 0, 0, 0 );
			 TEST($$); 
		      } else {
			 yyerror("Dimensions of DEFNULL arguments are not compatible");
			 YYERROR;
		      }
		   } else if (FSTRCMP($1,"ARCTAN2(") == 0) {
		     if( TYPE($2) != DOUBLE ) $2 = New_Unary( DOUBLE, 0, $2 );
		     if( TYPE($4) != DOUBLE ) $4 = New_Unary( DOUBLE, 0, $4 );
		     if( Test_Dims( $2, $4 ) ) {
			$$ = New_Func( 0, atan2_fct, 2, $2, $4, 0, 0, 0, 0, 0 );
			TEST($$); 
			if( SIZE($2)<SIZE($4) ) {
			   int i;
			   gParse.Nodes[$$].value.nelem =
			      gParse.Nodes[$4].value.nelem;
			   gParse.Nodes[$$].value.naxis =
			      gParse.Nodes[$4].value.naxis;
			   for( i=0; i<gParse.Nodes[$4].value.naxis; i++ )
			      gParse.Nodes[$$].value.naxes[i] =
				 gParse.Nodes[$4].value.naxes[i];
			}
		     } else {
			yyerror("Dimensions of arctan2 arguments are not compatible");
			YYERROR;
		     }
		  } else {
                     yyerror("Function(expr,expr) not supported");
		     YYERROR;
		  }
                }
       | expr '[' expr ']'
                { $$ = New_Deref( $1, 1, $3,  0,  0,  0,   0 ); TEST($$); }
       | expr '[' expr ',' expr ']'
                { $$ = New_Deref( $1, 2, $3, $5,  0,  0,   0 ); TEST($$); }
       | expr '[' expr ',' expr ',' expr ']'
                { $$ = New_Deref( $1, 3, $3, $5, $7,  0,   0 ); TEST($$); }
       | expr '[' expr ',' expr ',' expr ',' expr ']'
                { $$ = New_Deref( $1, 4, $3, $5, $7, $9,   0 ); TEST($$); }
       | expr '[' expr ',' expr ',' expr ',' expr ',' expr ']'
                { $$ = New_Deref( $1, 5, $3, $5, $7, $9, $11 ); TEST($$); }
       | INTCAST expr
		{ $$ = New_Unary( LONG,   INTCAST, $2 );  TEST($$);  }
       | INTCAST bexpr
                { $$ = New_Unary( LONG,   INTCAST, $2 );  TEST($$);  }
       | FLTCAST expr
		{ $$ = New_Unary( DOUBLE, FLTCAST, $2 );  TEST($$);  }
       | FLTCAST bexpr
                { $$ = New_Unary( DOUBLE, FLTCAST, $2 );  TEST($$);  }
       ;

bexpr:   BOOLEAN
                { $$ = New_Const( BOOLEAN, &($1), sizeof(char) ); TEST($$); }
       | BCOLUMN
                { $$ = New_Column( $1 ); TEST($$); }
       | bits EQ bits
                { $$ = New_BinOp( BOOLEAN, $1, EQ,  $3 ); TEST($$);
		  SIZE($$) = 1;                                     }
       | bits NE bits
                { $$ = New_BinOp( BOOLEAN, $1, NE,  $3 ); TEST($$); 
		  SIZE($$) = 1;                                     }
       | bits LT bits
                { $$ = New_BinOp( BOOLEAN, $1, LT,  $3 ); TEST($$); 
		  SIZE($$) = 1;                                     }
       | bits LTE bits
                { $$ = New_BinOp( BOOLEAN, $1, LTE, $3 ); TEST($$); 
		  SIZE($$) = 1;                                     }
       | bits GT bits
                { $$ = New_BinOp( BOOLEAN, $1, GT,  $3 ); TEST($$); 
		  SIZE($$) = 1;                                     }
       | bits GTE bits
                { $$ = New_BinOp( BOOLEAN, $1, GTE, $3 ); TEST($$); 
		  SIZE($$) = 1;                                     }
       | expr GT expr
                { PROMOTE($1,$3); $$ = New_BinOp( BOOLEAN, $1, GT,  $3 );
                  TEST($$);                                               }
       | expr LT expr
                { PROMOTE($1,$3); $$ = New_BinOp( BOOLEAN, $1, LT,  $3 );
                  TEST($$);                                               }
       | expr GTE expr
                { PROMOTE($1,$3); $$ = New_BinOp( BOOLEAN, $1, GTE, $3 );
                  TEST($$);                                               }
       | expr LTE expr
                { PROMOTE($1,$3); $$ = New_BinOp( BOOLEAN, $1, LTE, $3 );
                  TEST($$);                                               }
       | expr '~' expr
                { PROMOTE($1,$3); $$ = New_BinOp( BOOLEAN, $1, '~', $3 );
                  TEST($$);                                               }
       | expr EQ expr
                { PROMOTE($1,$3); $$ = New_BinOp( BOOLEAN, $1, EQ,  $3 );
                  TEST($$);                                               }
       | expr NE expr
                { PROMOTE($1,$3); $$ = New_BinOp( BOOLEAN, $1, NE,  $3 );
                  TEST($$);                                               }
       | sexpr EQ sexpr
                { $$ = New_BinOp( BOOLEAN, $1, EQ,  $3 ); TEST($$);
                  SIZE($$) = 1; }
       | sexpr NE sexpr
                { $$ = New_BinOp( BOOLEAN, $1, NE,  $3 ); TEST($$);
                  SIZE($$) = 1; }
       | bexpr AND bexpr
                { $$ = New_BinOp( BOOLEAN, $1, AND, $3 ); TEST($$); }
       | bexpr OR bexpr
                { $$ = New_BinOp( BOOLEAN, $1, OR,  $3 ); TEST($$); }
       | bexpr EQ bexpr
                { $$ = New_BinOp( BOOLEAN, $1, EQ,  $3 ); TEST($$); }
       | bexpr NE bexpr
                { $$ = New_BinOp( BOOLEAN, $1, NE,  $3 ); TEST($$); }

       | expr '=' expr ':' expr
                { PROMOTE($1,$3); PROMOTE($1,$5); PROMOTE($3,$5);
		  $3 = New_BinOp( BOOLEAN, $3, LTE, $1 );
                  $5 = New_BinOp( BOOLEAN, $1, LTE, $5 );
                  $$ = New_BinOp( BOOLEAN, $3, AND, $5 );
                  TEST($$);                                         }

       | BFUNCTION expr ')'
                {
		   if (FSTRCMP($1,"ISNULL(") == 0) {
		      $$ = New_Func( 0, isnull_fct, 1, $2, 0, 0,
				     0, 0, 0, 0 );
		      TEST($$); 
                      /* Use expression's size, but return BOOLEAN */
		      TYPE($$) = BOOLEAN;
		   } else {
		      yyerror("Boolean Function(expr) not supported");
		      YYERROR;
		   }
		}
       | BFUNCTION bexpr ')'
                {
		   if (FSTRCMP($1,"ISNULL(") == 0) {
		      $$ = New_Func( 0, isnull_fct, 1, $2, 0, 0,
				     0, 0, 0, 0 );
		      TEST($$); 
                      /* Use expression's size, but return BOOLEAN */
		      TYPE($$) = BOOLEAN;
		   } else {
		      yyerror("Boolean Function(expr) not supported");
		      YYERROR;
		   }
		}
       | BFUNCTION sexpr ')'
                {
		   if (FSTRCMP($1,"ISNULL(") == 0) {
		      $$ = New_Func( BOOLEAN, isnull_fct, 1, $2, 0, 0,
				     0, 0, 0, 0 );
		      TEST($$); 
		   } else {
		      yyerror("Boolean Function(expr) not supported");
		      YYERROR;
		   }
		}
       | FUNCTION bexpr ',' bexpr ')'
                {
		   if (FSTRCMP($1,"DEFNULL(") == 0) {
		      if( SIZE($2)>=SIZE($4) && Test_Dims( $2, $4 ) ) {
			 $$ = New_Func( 0, defnull_fct, 2, $2, $4, 0,
					0, 0, 0, 0 );
			 TEST($$); 
		      } else {
			 yyerror("Dimensions of DEFNULL arguments are not compatible");
			 YYERROR;
		      }
		   } else {
		      yyerror("Boolean Function(expr,expr) not supported");
		      YYERROR;
		   }
		}
       | BFUNCTION expr ',' expr ',' expr ')'
		{
		   if( SIZE($2)>1 || SIZE($4)>1 || SIZE($6)>1 ) {
		      yyerror("Cannot use array as function argument");
		      YYERROR;
		   }
		   if( TYPE($2) != DOUBLE ) $2 = New_Unary( DOUBLE, 0, $2 );
		   if( TYPE($4) != DOUBLE ) $4 = New_Unary( DOUBLE, 0, $4 );
		   if( TYPE($6) != DOUBLE ) $6 = New_Unary( DOUBLE, 0, $6 );
		   if (FSTRCMP($1,"NEAR(") == 0)
		      $$ = New_Func( BOOLEAN, near_fct, 3, $2, $4, $6,
				     0, 0, 0, 0 );
		   else {
		      yyerror("Boolean Function not supported");
		      YYERROR;
		   }
                   TEST($$); 
		}
       | BFUNCTION expr ',' expr ',' expr ',' expr ',' expr ')'
	        {
		   if( SIZE($2)>1 || SIZE($4)>1 || SIZE($6)>1 || SIZE($8)>1
		       || SIZE($10)>1 ) {
		      yyerror("Cannot use array as function argument");
		      YYERROR;
		   }
		   if( TYPE($2) != DOUBLE ) $2 = New_Unary( DOUBLE, 0, $2 );
		   if( TYPE($4) != DOUBLE ) $4 = New_Unary( DOUBLE, 0, $4 );
		   if( TYPE($6) != DOUBLE ) $6 = New_Unary( DOUBLE, 0, $6 );
		   if( TYPE($8) != DOUBLE ) $8 = New_Unary( DOUBLE, 0, $8 );
		   if( TYPE($10)!= DOUBLE ) $10= New_Unary( DOUBLE, 0, $10);
                   if (FSTRCMP($1,"CIRCLE(") == 0)
		      $$ = New_Func( BOOLEAN, circle_fct, 5, $2, $4, $6, $8,
				     $10, 0, 0 );
		   else {
		      yyerror("Boolean Function not supported");
		      YYERROR;
		   }
                   TEST($$); 
		}
       | BFUNCTION expr ',' expr ',' expr ',' expr ',' expr ',' expr ',' expr ')'
                {
		   if( SIZE($2)>1 || SIZE($4)>1 || SIZE($6)>1 || SIZE($8)>1
		       || SIZE($10)>1 || SIZE($12)>1 || SIZE($14)>1 ) {
		      yyerror("Cannot use array as function argument");
		      YYERROR;
		   }
		   if( TYPE($2) != DOUBLE ) $2 = New_Unary( DOUBLE, 0, $2 );
		   if( TYPE($4) != DOUBLE ) $4 = New_Unary( DOUBLE, 0, $4 );
		   if( TYPE($6) != DOUBLE ) $6 = New_Unary( DOUBLE, 0, $6 );
		   if( TYPE($8) != DOUBLE ) $8 = New_Unary( DOUBLE, 0, $8 );
		   if( TYPE($10)!= DOUBLE ) $10= New_Unary( DOUBLE, 0, $10);
		   if( TYPE($12)!= DOUBLE ) $12= New_Unary( DOUBLE, 0, $12);
		   if( TYPE($14)!= DOUBLE ) $14= New_Unary( DOUBLE, 0, $14);
		   if (FSTRCMP($1,"BOX(") == 0)
		      $$ = New_Func( BOOLEAN, box_fct, 7, $2, $4, $6, $8,
				      $10, $12, $14 );
		   else if (FSTRCMP($1,"ELLIPSE(") == 0)
		      $$ = New_Func( BOOLEAN, elps_fct, 7, $2, $4, $6, $8,
				      $10, $12, $14 );
		   else {
		      yyerror("SAO Image Function not supported");
		      YYERROR;
		   }
                   TEST($$); 
		}
       | bexpr '[' expr ']'
                { $$ = New_Deref( $1, 1, $3,  0,  0,  0,   0 ); TEST($$); }
       | bexpr '[' expr ',' expr ']'
                { $$ = New_Deref( $1, 2, $3, $5,  0,  0,   0 ); TEST($$); }
       | bexpr '[' expr ',' expr ',' expr ']'
                { $$ = New_Deref( $1, 3, $3, $5, $7,  0,   0 ); TEST($$); }
       | bexpr '[' expr ',' expr ',' expr ',' expr ']'
                { $$ = New_Deref( $1, 4, $3, $5, $7, $9,   0 ); TEST($$); }
       | bexpr '[' expr ',' expr ',' expr ',' expr ',' expr ']'
                { $$ = New_Deref( $1, 5, $3, $5, $7, $9, $11 ); TEST($$); }
       | NOT bexpr
                { $$ = New_Unary( BOOLEAN, NOT, $2 ); TEST($$); }
       | '(' bexpr ')'
                { $$ = $2; }
       ;

sexpr:   STRING
                { $$ = New_Const( STRING, $1, strlen($1)+1 ); TEST($$);
                  SIZE($$) = strlen($1);                            }
       | SCOLUMN
                { $$ = New_Column( $1 ); TEST($$); }
       | '(' sexpr ')'
                { $$ = $2; }
       | sexpr '+' sexpr
                { $$ = New_BinOp( STRING, $1, '+', $3 );  TEST($$);
		  SIZE($$) = SIZE($1) + SIZE($3);                   }
       | FUNCTION sexpr ',' sexpr ')'
                { 
		  if (FSTRCMP($1,"DEFNULL(") == 0) {
		     $$ = New_Func( 0, defnull_fct, 2, $2, $4, 0,
				    0, 0, 0, 0 );
		     TEST($$); 
		     if( SIZE($4)>SIZE($2) ) SIZE($$) = SIZE($4);
		  }
		}
	;

%%

/*************************************************************************/
/*  Start of "New" routines which build the expression Nodal structure   */
/*************************************************************************/

static int Alloc_Node( void )
{
                      /* Use this for allocation to guarantee *Nodes */
   Node *newNodePtr;  /* survives on failure, making it still valid  */
                      /* while working our way out of this error     */

   if( gParse.nNodes == gParse.nNodesAlloc ) {
      if( gParse.Nodes ) {
	 gParse.nNodesAlloc += gParse.nNodesAlloc;
	 newNodePtr = (Node *)realloc( gParse.Nodes,
				       sizeof(Node)*gParse.nNodesAlloc );
      } else {
	 gParse.nNodesAlloc = 100;
	 newNodePtr = (Node *)malloc ( sizeof(Node)*gParse.nNodesAlloc );
      }	 

      if( newNodePtr ) {
	 gParse.Nodes = newNodePtr;
      } else {
	 gParse.status = MEMORY_ALLOCATION;
	 return( -1 );
      }
   }

   return ( gParse.nNodes++ );
}

static void Free_Last_Node( void )
{
   if( gParse.nNodes ) gParse.nNodes--;
}

static int New_Const( int returnType, void *value, long len )
{
   Node *this;
   int n;

   n = Alloc_Node();
   if( n>=0 ) {
      this             = gParse.Nodes + n;
      this->operation  = -1000;             /* Flag a constant */
      this->nSubNodes  = 0;
      this->type       = returnType;
      memcpy( &(this->value.data), value, len );
      this->value.undef = NULL;
      this->value.nelem = 1;
      this->value.naxis = 1;
      this->value.naxes[0] = 1;
   }
   return(n);
}

static int New_Column( int ColNum )
{
   Node *this;
   int  n, i;

   n = Alloc_Node();
   if( n>=0 ) {
      this              = gParse.Nodes + n;
      this->operation   = -ColNum;
      this->nSubNodes   = 0;
      this->type        = gParse.colInfo[ColNum].type;
      this->value.nelem = gParse.colInfo[ColNum].nelem;
      this->value.naxis = gParse.colInfo[ColNum].naxis;
      for( i=0; i<gParse.colInfo[ColNum].naxis; i++ )
	 this->value.naxes[i] = gParse.colInfo[ColNum].naxes[i];
   }
   return(n);
}

static int New_Unary( int returnType, int Op, int Node1 )
{
   Node *this, *that;
   int  i,n;

   if( Node1<0 ) return(-1);
   that = gParse.Nodes + Node1;

   if( !Op ) Op = returnType;

   if( (Op==DOUBLE || Op==FLTCAST) && that->type==DOUBLE  ) return( Node1 );
   if( (Op==LONG   || Op==INTCAST) && that->type==LONG    ) return( Node1 );
   if( (Op==BOOLEAN              ) && that->type==BOOLEAN ) return( Node1 );

   if( that->operation==-1000 ) {  /* Operating on a constant! */
      switch( Op ) {
      case DOUBLE:
      case FLTCAST:
	 if( that->type==LONG )
	    that->value.data.dbl = (double)that->value.data.lng;
	 else if( that->type==BOOLEAN )
	    that->value.data.dbl = ( that->value.data.log ? 1.0 : 0.0 );
	 that->type=DOUBLE;
	 return(Node1);
	 break;
      case LONG:
      case INTCAST:
	 if( that->type==DOUBLE )
	    that->value.data.lng = (long)that->value.data.dbl;
	 else if( that->type==BOOLEAN )
	    that->value.data.lng = ( that->value.data.log ? 1L : 0L );
	 that->type=LONG;
	 return(Node1);
	 break;
      case BOOLEAN:
	 if( that->type==DOUBLE )
	    that->value.data.log = ( that->value.data.dbl != 0.0 );
	 else if( that->type==LONG )
	    that->value.data.log = ( that->value.data.lng != 0L );
	 that->type=BOOLEAN;
	 return(Node1);
	 break;
      case UMINUS:
	 if( that->type==DOUBLE )
	    that->value.data.dbl = - that->value.data.dbl;
	 else if( that->type==LONG )
	    that->value.data.lng = - that->value.data.lng;
	 return(Node1);
	 break;
      case NOT:
	 if( that->type==BOOLEAN )
	    that->value.data.log = ( ! that->value.data.log );
	 else if( that->type==BITSTR )
	    bitnot( that->value.data.str, that->value.data.str );
	 return(Node1);
	 break;
      }
   }
   
   n = Alloc_Node();
   if( n>=0 ) {
      this              = gParse.Nodes + n;
      this->operation   = Op;
      this->nSubNodes   = 1;
      this->SubNodes[0] = Node1;
      this->type        = returnType;

      that              = gParse.Nodes + Node1; /* Reset in case .Nodes mv'd */
      this->value.nelem = that->value.nelem;
      this->value.naxis = that->value.naxis;
      for( i=0; i<that->value.naxis; i++ )
	 this->value.naxes[i] = that->value.naxes[i];
   }
   return( n );
}

static int New_BinOp( int returnType, int Node1, int Op, int Node2 )
{
   Node *this,*that1,*that2;
   int  n,i;

   if( Node1<0 || Node2<0 ) return(-1);

   n = Alloc_Node();
   if( n>=0 ) {
      this             = gParse.Nodes + n;
      this->operation  = Op;
      this->nSubNodes  = 2;
      this->SubNodes[0]= Node1;
      this->SubNodes[1]= Node2;
      this->type       = returnType;

      that1            = gParse.Nodes + Node1;
      that2            = gParse.Nodes + Node2;
      if( that1->type!=STRING && that1->type!=BITSTR )
	 if( !Test_Dims( Node1, Node2 ) ) {
	    Free_Last_Node();
	    ffpmsg("Array sizes/dims do not match for binary operator");
	    return(-1);
	 }
      if( that1->value.nelem == 1 ) that1 = that2;

      this->value.nelem = that1->value.nelem;
      this->value.naxis = that1->value.naxis;
      for( i=0; i<that1->value.naxis; i++ )
	 this->value.naxes[i] = that1->value.naxes[i];
   }
   return( n );
}

static int New_Func( int returnType, funcOp Op, int nNodes,
		     int Node1, int Node2, int Node3, int Node4, 
		     int Node5, int Node6, int Node7 )
/* If returnType==0 , use Node1's type and vector sizes as returnType, */
/* else return a single value of type returnType                       */
{
   Node *this, *that;
   int  i,n;

   if( Node1<0 || Node2<0 || Node3<0 || Node4<0 || 
       Node5<0 || Node6<0 || Node7<0 ) return(-1);

   n = Alloc_Node();
   if( n>=0 ) {
      this              = gParse.Nodes + n;
      this->operation   = (int)Op;
      this->nSubNodes   = nNodes;
      this->SubNodes[0] = Node1;
      this->SubNodes[1] = Node2;
      this->SubNodes[2] = Node3;
      this->SubNodes[3] = Node4;
      this->SubNodes[4] = Node5;
      this->SubNodes[5] = Node6;
      this->SubNodes[6] = Node7;
      
      if( returnType ) {
	 this->type           = returnType;
	 this->value.nelem    = 1;
	 this->value.naxis    = 1;
	 this->value.naxes[0] = 1;
      } else {
	 that              = gParse.Nodes + Node1;
	 this->type        = that->type;
	 this->value.nelem = that->value.nelem;
	 this->value.naxis = that->value.naxis;
	 for( i=0; i<that->value.naxis; i++ )
	    this->value.naxes[i] = that->value.naxes[i];
      }
   }
   return( n );
}

static int New_Deref( int Var,  int nDim,
		      int Dim1, int Dim2, int Dim3, int Dim4, int Dim5 )
{
   int n, idx;
   long elem=0;
   Node *this, *theVar, *theDim[MAXDIMS];

   if( Var<0 || Dim1<0 || Dim2<0 || Dim3<0 || Dim4<0 || Dim5<0 ) return(-1);

   theVar = gParse.Nodes + Var;
   if( theVar->operation==-1000 || theVar->value.nelem==1 ) {
      ffpmsg("Cannot index a scalar value");
      gParse.status = PARSE_SYNTAX_ERR;
      return(-1);
   }

   n = Alloc_Node();
   if( n>=0 ) {
      this              = gParse.Nodes + n;
      this->nSubNodes   = nDim+1;
      theVar            = gParse.Nodes + (this->SubNodes[0]=Var);
      theDim[0]         = gParse.Nodes + (this->SubNodes[1]=Dim1);
      theDim[1]         = gParse.Nodes + (this->SubNodes[2]=Dim2);
      theDim[2]         = gParse.Nodes + (this->SubNodes[3]=Dim3);
      theDim[3]         = gParse.Nodes + (this->SubNodes[4]=Dim4);
      theDim[4]         = gParse.Nodes + (this->SubNodes[5]=Dim5);

      for( idx=0; idx<nDim; idx++ )
	 if( theDim[idx]->value.nelem>1 ) {
	    Free_Last_Node();
	    ffpmsg("Cannot use an array as an index value");
	    gParse.status = PARSE_SYNTAX_ERR;
	    return(-1);
	 } else if( theDim[idx]->type!=LONG ) {
	    Free_Last_Node();
	    yyerror("Index value must be an integer type");
	    return(-1);
	 }

      this->operation   = '[';
      this->type        = theVar->type;

      if( theVar->value.naxis == nDim ) { /* All dimensions specified */
	 this->value.nelem    = 1;
	 this->value.naxis    = 1;
	 this->value.naxes[0] = 1;
      } else if( nDim==1 ) { /* Dereference only one dimension */
	 elem=1;
	 this->value.naxis = theVar->value.naxis-1;
	 for( idx=0; idx<this->value.naxis; idx++ ) {
	    elem *= ( this->value.naxes[idx] = theVar->value.naxes[idx] );
	 }
	 this->value.nelem = elem;
      } else {
	 Free_Last_Node();
	 yyerror("Must specify just one or all indices for vector");
	 return(-1);
      }
   }
   return(n);
}

static int Test_Dims( int Node1, int Node2 )
{
   Node *that1, *that2;
   int valid, i;

   if( Node1<0 || Node2<0 ) return(0);

   that1 = gParse.Nodes + Node1;
   that2 = gParse.Nodes + Node2;

   if( that1->value.nelem==1 || that2->value.nelem==1 )
      valid = 1;
   else if( that1->type==that2->type
	    && that1->value.nelem==that2->value.nelem
	    && that1->value.naxis==that2->value.naxis ) {
      valid = 1;
      for( i=0; i<that1->value.naxis; i++ ) {
	 if( that1->value.naxes[i]!=that2->value.naxes[i] )
	    valid = 0;
      }
   } else
      valid = 0;
   return( valid );
}   

/********************************************************************/
/*    Routines for actually evaluating the expression start here    */
/********************************************************************/

void Evaluate_Node( int thisNode )
    /**********************************************************************/
    /*  Recursively evaluate thisNode's subNodes, then call one of the    */
    /*  Do_<Action> functions based on what operation is being performed. */
    /**********************************************************************/
{
   Node *this;
   int i;
   
   if( gParse.status ) return;

   this = gParse.Nodes + thisNode;
   if( this->operation<=0 ) return;

   i = this->nSubNodes;
   while( i-- ) {
      Evaluate_Node( this->SubNodes[i] );
      if( gParse.status ) return;
   }

   if( this->operation>1000 )

      Do_Func( this );

   else {
      switch( this->operation ) {

	 /* Unary Operators */

      case BOOLEAN:
      case LONG:
      case INTCAST:
      case DOUBLE:
      case FLTCAST:
      case NOT:
      case UMINUS:
	 Do_Unary( this );
	 break;

         /* Binary Operators */

      case OR:
      case AND:
      case EQ:
      case NE:
      case '~':
      case GT:
      case LT:
      case LTE:
      case GTE:
      case '+': 
      case '-': 
      case '%': 
      case '*': 
      case '/': 
      case '|': 
      case '&': 
      case POWER:
	 /*  Both subnodes should be of same time  */
	 switch( gParse.Nodes[ this->SubNodes[0] ].type ) {
	 case BITSTR:  Do_BinOp_bit( this );  break;
         case STRING:  Do_BinOp_str( this );  break;
         case BOOLEAN: Do_BinOp_log( this );  break;
         case LONG:    Do_BinOp_lng( this );  break;
         case DOUBLE:  Do_BinOp_dbl( this );  break;
	 }
	 break;

      case '[':
	 /*  All subnodes should be LONGs and scalar/constant  */
         Do_Deref( this );
	 break;

      default:
	 /* BAD Operator! */
	 yyerror("Unknown operator encountered during evaluation");
	 break;
      }
   }
}

void Reset_Parser( long firstRow, long rowOffset, long nRows )
    /***********************************************************************/
    /*  Reset the parser for processing another batch of data...           */
    /*    firstRow:  Row number of the first element of the iterCol.array  */
    /*    rowOffset: How many rows of iterCol.array should be skipped      */
    /*    nRows:     Number of rows to be processed                        */
    /*  Then, allocate and initialize the necessary UNDEF arrays for each  */
    /*  column used by the parser.  Finally, initialize each COLUMN node   */
    /*  so that its UNDEF and DATA pointers point to the appropriate       */
    /*  column arrays.                                                     */
    /***********************************************************************/
{
   int     i, column;
   long    nelem, len, row, offset, idx;
   char  **bitStrs;
   char  **sptr;
   char   *barray;
   long   *iarray;
   double *rarray;

   gParse.nRows    = nRows;
   gParse.firstRow = firstRow + rowOffset;

   /*  Resize and fill in UNDEF arrays for each column  */

   for( i=0; i<gParse.nCols; i++ ) {
      if( gParse.colData[i].iotype == OutputCol ) continue;

      nelem  = gParse.colInfo[i].nelem;
      len    = nelem * nRows;
      offset = nelem * rowOffset + 1; /* Skip initial NULLVAL in [0] elem */

      switch ( gParse.colInfo[i].type ) {
      case BITSTR:
      /* No need for UNDEF array, but must make string DATA array */
	 len = (nelem+1)*nRows;   /* Count '\0' */
	 bitStrs = (char**)gParse.colNulls[i];
	 if( bitStrs ) free( bitStrs[0] );
	 free( bitStrs );
	 bitStrs = (char**)malloc( nRows*sizeof(char*) );
	 if( bitStrs==NULL ) {
	    gParse.status = MEMORY_ALLOCATION;
	    break;
	 }
	 bitStrs[0] = (char*)malloc( len*sizeof(char) );
	 if( bitStrs[0]==NULL ) {
	    free( bitStrs );
	    gParse.colNulls[i] = NULL;
	    gParse.status = MEMORY_ALLOCATION;
	    break;
	 }

	 for( row=0; row<gParse.nRows; row++ ) {
	    bitStrs[row] = bitStrs[0] + row*(nelem+1);
	    idx = (row+rowOffset)*( (nelem+7)/8 ) + 1;
	    for(len=0; len<nelem; len++) {
	       if( ((char*)gParse.colData[i].array)[idx] & (1<<(7-len%8)) )
		  bitStrs[row][len] = '1';
	       else
		  bitStrs[row][len] = '0';
	       if( len%8==7 ) idx++;
	    }
	    bitStrs[row][len] = '\0';
	 }
	 gParse.colNulls[i] = (char*)bitStrs;
	 break;
      case STRING:
	 sptr = (char**)gParse.colData[i].array;
	 free( gParse.colNulls[i] );
	 gParse.colNulls[i] = (char*)malloc( nRows*sizeof(char) );
	 if( gParse.colNulls[i]==NULL ) {
	    gParse.status = MEMORY_ALLOCATION;
	    break;
	 }
	 for( row=0; row<nRows; row++ ) {
	    if( **sptr != '\0' && FSTRCMP( sptr[0], sptr[row+rowOffset+1] )==0 )
	       gParse.colNulls[i][row] = 1;
	    else
	       gParse.colNulls[i][row] = 0;
	 }
	 break;
      case BOOLEAN:
	 barray = (char*)gParse.colData[i].array;
	 free( gParse.colNulls[i] );
	 gParse.colNulls[i] = (char*)malloc( len*sizeof(char) );
	 if( gParse.colNulls[i]==NULL ) {
	    gParse.status = MEMORY_ALLOCATION;
	    break;
	 }
	 while( len-- ) {
	    gParse.colNulls[i][len] = 
	       ( barray[0]!=0 && barray[0]==barray[len+offset] );
	 }
	 break;
      case LONG:
	 iarray = (long*)gParse.colData[i].array;
	 free( gParse.colNulls[i] );
	 gParse.colNulls[i] = (char*)malloc( len*sizeof(char) );
	 if( gParse.colNulls[i]==NULL ) {
	    gParse.status = MEMORY_ALLOCATION;
	    break;
	 }
	 while( len-- ) {
	    gParse.colNulls[i][len] = 
	       ( iarray[0]!=0L && iarray[0]==iarray[len+offset] );
	 }
	 break;
      case DOUBLE:
	 rarray = (double*)gParse.colData[i].array;
	 free( gParse.colNulls[i] );
	 gParse.colNulls[i] = (char*)malloc( len*sizeof(char) );
	 if( gParse.colNulls[i]==NULL ) {
	    gParse.status = MEMORY_ALLOCATION;
	    break;
	 }
	 while( len-- ) {
	    gParse.colNulls[i][len] = 
	       ( rarray[0]!=0.0 && rarray[0]==rarray[len+offset]);
	 }
	 break;
      }
      if( gParse.status ) {  /*  Deallocate NULL arrays of previous columns */
	 while( i-- ) {
	    if( gParse.colInfo[i].type==BITSTR )
	       free( ((char**)gParse.colNulls[i])[0] );
	    free( gParse.colNulls[i] );
	    gParse.colNulls[i] = NULL;
	 }
	 return;
      }
   }

   /*  Reset Column Nodes' pointers to point to right data and UNDEF arrays  */

   for( i=0; i<gParse.nNodes; i++ ) {
      if(    gParse.Nodes[i].operation >  0
	  || gParse.Nodes[i].operation == -1000 ) continue;

      column = -gParse.Nodes[i].operation;
      offset = gParse.colInfo[column].nelem * rowOffset + 1;

      gParse.Nodes[i].value.undef = gParse.colNulls[column];

      switch( gParse.Nodes[i].type ) {
      case BITSTR:
	 gParse.Nodes[i].value.data.strptr = (char**)gParse.colNulls[column];
	 gParse.Nodes[i].value.undef       = NULL;
	 break;
      case STRING:
	 gParse.Nodes[i].value.data.strptr = 
	    ((char**)gParse.colData[column].array)+rowOffset+1;
	 break;
      case BOOLEAN:
	 gParse.Nodes[i].value.data.logptr = 
	    ((char*)gParse.colData[column].array)+offset;
	 break;
      case LONG:
	 gParse.Nodes[i].value.data.lngptr = 
	    ((long*)gParse.colData[column].array)+offset;
	 break;
      case DOUBLE:
	 gParse.Nodes[i].value.data.dblptr = 
	    ((double*)gParse.colData[column].array)+offset;
	 break;
      }
   }
}

static void Allocate_Ptrs( Node *this )
{
   long elem, row;

   if( this->type==BITSTR || this->type==STRING ) {

      this->value.data.strptr = (char**)malloc( gParse.nRows
						* sizeof(char*) );
      if( this->value.data.strptr ) {
	 this->value.data.strptr[0] = (char*)malloc( gParse.nRows
						     * (this->value.nelem+1)
						     * sizeof(char) );
	 if( this->value.data.strptr[0] ) {
	    row = 0;
	    while( (++row)<gParse.nRows ) {
	       this->value.data.strptr[row] =
		  this->value.data.strptr[row-1] + this->value.nelem+1;
	    }
	    if( this->type==STRING ) {
	       this->value.undef = (char*)malloc( gParse.nRows*sizeof(char) );
	       if( this->value.undef==NULL ) {
		  gParse.status = MEMORY_ALLOCATION;
		  free( this->value.data.strptr[0] );
		  free( this->value.data.strptr );
	       }
	    } else {
	       this->value.undef = NULL;  /* BITSTRs don't use undef array */
	    }
	 } else {
	    gParse.status = MEMORY_ALLOCATION;
	    free( this->value.data.strptr );
	 }
      } else {
	 gParse.status = MEMORY_ALLOCATION;
      }

   } else {

      elem = this->value.nelem * gParse.nRows;

      this->value.undef = (char*)malloc( elem*sizeof(char) );
      if( this->value.undef ) {

	 if( this->type==DOUBLE ) {
	    this->value.data.dblptr = (double*)malloc( elem*sizeof(double) );
	 } else if( this->type==LONG ) {
	    this->value.data.lngptr = (long  *)malloc( elem*sizeof(long  ) );
	 } else if( this->type==BOOLEAN ) {
	    this->value.data.logptr = (char  *)malloc( elem*sizeof(char  ) );
	 }	 
      
	 if( this->value.data.ptr==NULL ) {
	    gParse.status = MEMORY_ALLOCATION;
	    free( this->value.undef );
	 }

      } else {
	 gParse.status = MEMORY_ALLOCATION;
      }
   }
}
static void Do_Unary( Node *this )
{
   Node *that;
   long elem;

   /*  New_Unary pre-evaluates operations on constants,  */
   /*  so no need to worry about that case               */

   that = gParse.Nodes + this->SubNodes[0];

   Allocate_Ptrs( this );

   if( !gParse.status ) {

      if( this->type!=BITSTR ) {
	 elem = gParse.nRows;
	 if( this->type!=STRING )
	    elem *= this->value.nelem;
	 while( elem-- )
	    this->value.undef[elem] = that->value.undef[elem];
      }

      elem = gParse.nRows * this->value.nelem;

      switch( this->operation ) {

      case BOOLEAN:
	 if( that->type==DOUBLE )
	    while( elem-- )
	       this->value.data.logptr[elem] =
		  ( that->value.data.dblptr[elem] != 0.0 );
	 else if( that->type==LONG )
	    while( elem-- )
	       this->value.data.logptr[elem] =
		  ( that->value.data.lngptr[elem] != 0L );
	 break;

      case DOUBLE:
      case FLTCAST:
	 if( that->type==LONG )
	    while( elem-- )
	       this->value.data.dblptr[elem] =
		  (double)that->value.data.lngptr[elem];
	 else if( that->type==BOOLEAN )
	    while( elem-- )
	       this->value.data.dblptr[elem] =
		  ( that->value.data.logptr[elem] ? 1.0 : 0.0 );
	 break;

      case LONG:
      case INTCAST:
	 if( that->type==DOUBLE )
	    while( elem-- )
	       this->value.data.lngptr[elem] =
		  (long)that->value.data.dblptr[elem];
	 else if( that->type==BOOLEAN )
	    while( elem-- )
	       this->value.data.lngptr[elem] =
		  ( that->value.data.logptr[elem] ? 1L : 0L );
	 break;

      case UMINUS:
	 if( that->type==DOUBLE ) {
	    while( elem-- )
	       this->value.data.dblptr[elem] =
		  - that->value.data.dblptr[elem];
	 } else if( that->type==LONG ) {
	    while( elem-- )
	       this->value.data.lngptr[elem] =
		  - that->value.data.lngptr[elem];
	 }
	 break;

      case NOT:
	 if( that->type==BOOLEAN ) {
	    while( elem-- )
	       this->value.data.logptr[elem] =
		  ( ! that->value.data.logptr[elem] );
	 } else if( that->type==BITSTR ) {
	    elem = gParse.nRows;
	    while( elem-- )
	       bitnot( this->value.data.strptr[elem],
		       that->value.data.strptr[elem] );
	 }
	 break;
      }
   }

   if( that->operation>0 ) {
      free( that->value.data.ptr );
      if( that->type!=BITSTR ) free( that->value.undef );
   }
}

static void Do_BinOp_bit( Node *this )
{
   Node *that1, *that2;
   char *sptr1, *sptr2, val;
   int  const1, const2;
   long rows;

   that1 = gParse.Nodes + this->SubNodes[0];
   that2 = gParse.Nodes + this->SubNodes[1];

   const1 = ( that1->operation==-1000 );
   const2 = ( that2->operation==-1000 );
   if( const1 ) sptr1 = that1->value.data.str;
   if( const2 ) sptr2 = that2->value.data.str;

   if( const1 && const2 ) {
      switch( this->operation ) {
      case NE:
	 this->value.data.log = !bitcmp( sptr1, sptr2 );
	 break;
      case EQ:
	 this->value.data.log =  bitcmp( sptr1, sptr2 );
	 break;
      case GT:
      case LT:
      case LTE:
      case GTE:
	 this->value.data.log = bitlgte( sptr1, this->operation, sptr2 );
	 break;
      case '|': 
	 bitor( this->value.data.str, sptr1, sptr2 );
	 break;
      case '&': 
	 bitand( this->value.data.str, sptr1, sptr2 );
	 break;
      case '+':
	 strcpy( this->value.data.str, sptr1 );
	 strcat( this->value.data.str, sptr2 );
	 break;
      }
      this->operation = -1000;

   } else {

      Allocate_Ptrs( this );

      if( !gParse.status ) {
	 rows  = gParse.nRows;
	 switch( this->operation ) {

	    /*  BITSTR comparisons  */

	 case NE:
	 case EQ:
	 case GT:
	 case LT:
	 case LTE:
	 case GTE:
	    while( rows-- ) {
	       if( !const1 )
		  sptr1 = that1->value.data.strptr[rows];
	       if( !const2 )
		  sptr2 = that2->value.data.strptr[rows];
	       switch( this->operation ) {
	       case NE:  val = !bitcmp( sptr1, sptr2 );  break;
	       case EQ:  val =  bitcmp( sptr1, sptr2 );  break;
	       case GT:
	       case LT:
	       case LTE:
	       case GTE: val = bitlgte( sptr1, this->operation, sptr2 );
		  break;
	       }
	       this->value.data.logptr[rows] = val;
	       this->value.undef[rows] = 0;
	    }
	    break;
	 
	    /*  BITSTR AND/ORs ...  no UNDEFS in or out */
      
	 case '|': 
	 case '&': 
	 case '+':
	    while( rows-- ) {
	       if( !const1 )
		  sptr1 = that1->value.data.strptr[rows];
	       if( !const2 )
		  sptr2 = that2->value.data.strptr[rows];
	       if( this->operation=='|' )
		  bitor(  this->value.data.strptr[rows], sptr1, sptr2 );
	       else if( this->operation=='&' )
		  bitand( this->value.data.strptr[rows], sptr1, sptr2 );
	       else {
		  strcpy( this->value.data.strptr[rows], sptr1 );
		  strcat( this->value.data.strptr[rows], sptr2 );
	       }
	    }
	    break;
	 }
      }
   }

   if( that1->operation>0 ) {
      free( that1->value.data.strptr[0] );
      free( that1->value.data.strptr    );
   }
   if( that2->operation>0 ) {
      free( that2->value.data.strptr[0] );
      free( that2->value.data.strptr    );
   }
}

static void Do_BinOp_str( Node *this )
{
   Node *that1, *that2;
   char *sptr1, *sptr2, null1, null2;
   int const1, const2, val;
   long rows;

   that1 = gParse.Nodes + this->SubNodes[0];
   that2 = gParse.Nodes + this->SubNodes[1];

   const1 = ( that1->operation==-1000 );
   const2 = ( that2->operation==-1000 );
   if( const1 ) {
      sptr1 = that1->value.data.str;
      null1 = 0;
   }
   if( const2 ) {
      sptr2 = that2->value.data.str;
      null2 = 0;
   }

   if( const1 && const2 ) {  /*  Result is a constant  */
      switch( this->operation ) {

	 /*  Compare Strings  */

      case NE:
      case EQ:
	 val = ( FSTRCMP( sptr1, sptr2 ) == 0 );
	 this->value.data.log = ( this->operation==EQ ? val : !val );
	 break;

	 /*  Concat Strings  */

      case '+':
	 strcpy( this->value.data.str, sptr1 );
	 strcat( this->value.data.str, sptr2 );
	 break;
      }
      this->operation = -1000;

   } else {  /*  Not a constant  */

      Allocate_Ptrs( this );

      if( !gParse.status ) {

	 rows = gParse.nRows;
	 switch( this->operation ) {

	    /*  Compare Strings  */

	 case NE:
	 case EQ:
	    while( rows-- ) {
	       if( !const1 ) null1 = that1->value.undef[rows];
	       if( !const2 ) null2 = that2->value.undef[rows];
	       this->value.undef[rows] = (null1 || null2);
	       if( ! this->value.undef[rows] ) {
		  if( !const1 ) sptr1  = that1->value.data.strptr[rows];
		  if( !const2 ) sptr2  = that2->value.data.strptr[rows];
		  val = ( FSTRCMP( sptr1, sptr2 ) == 0 );
		  this->value.data.logptr[rows] =
		     ( this->operation==EQ ? val : !val );
	       }
	    }
	    break;
	    
	    /*  Concat Strings  */
	    
	 case '+':
	    while( rows-- ) {
	       if( !const1 ) null1 = that1->value.undef[rows];
	       if( !const2 ) null2 = that2->value.undef[rows];
	       this->value.undef[rows] = (null1 || null2);
	       if( ! this->value.undef[rows] ) {
		  if( !const1 ) sptr1  = that1->value.data.strptr[rows];
		  if( !const2 ) sptr2  = that2->value.data.strptr[rows];
		  strcpy( this->value.data.strptr[rows], sptr1 );
		  strcat( this->value.data.strptr[rows], sptr2 );
	       }
	    }
	    break;
	 }
      }
   }

   if( that1->operation>0 ) {
      free( that1->value.data.strptr[0] );
      free( that1->value.data.strptr );
      free( that1->value.undef );
   }
   if( that2->operation>0 ) {
      free( that2->value.data.strptr[0] );
      free( that2->value.data.strptr );
      free( that2->value.undef );
   }
}

static void Do_BinOp_log( Node *this )
{
   Node *that1, *that2;
   int vector1, vector2;
   char val1, val2, null1, null2;
   long rows, nelem, elem;

   that1 = gParse.Nodes + this->SubNodes[0];
   that2 = gParse.Nodes + this->SubNodes[1];

   vector1 = ( that1->operation!=-1000 );
   if( vector1 )
      vector1 = that1->value.nelem;
   else {
      val1  = that1->value.data.log;
      null1 = 0;
   }

   vector2 = ( that2->operation!=-1000 );
   if( vector2 )
      vector2 = that2->value.nelem;
   else {
      val2  = that2->value.data.log;
      null2 = 0;
   }

   if( !vector1 && !vector2 ) {  /*  Result is a constant  */
      switch( this->operation ) {
      case OR:
	 this->value.data.log = (val1 || val2);
	 break;
      case AND:
	 this->value.data.log = (val1 && val2);
	 break;
      case EQ:
	 this->value.data.log = ( (val1 && val2) || (!val1 && !val2) );
	 break;
      case NE:
	 this->value.data.log = ( (val1 && !val2) || (!val1 && val2) );
	 break;
      }
      this->operation=-1000;
   } else {
      rows  = gParse.nRows;
      nelem = this->value.nelem;
      elem  = this->value.nelem * rows;

      Allocate_Ptrs( this );

      if( !gParse.status ) {
	 while( rows-- ) {
	    while( nelem-- ) {
	       elem--;

	       if( vector1>1 ) {
		  val1  = that1->value.data.logptr[elem];
		  null1 = that1->value.undef[elem];
	       } else if( vector1 ) {
		  val1  = that1->value.data.logptr[rows];
		  null1 = that1->value.undef[rows];
	       }

	       if( vector2>1 ) {
		  val2  = that2->value.data.logptr[elem];
		  null2 = that2->value.undef[elem];
	       } else if( vector2 ) {
		  val2  = that2->value.data.logptr[rows];
		  null2 = that2->value.undef[rows];
	       }

	       this->value.undef[elem] = (null1 || null2);
	       switch( this->operation ) {

	       case OR:
		  /*  This is more complicated than others to suppress UNDEFs */
		  /*  in those cases where the other argument is DEF && TRUE  */

		  if( !null1 && !null2 ) {
		     this->value.data.logptr[elem] = (val1 || val2);
		  } else if( (null1 && !null2 && val2)
			     || ( !null1 && null2 && val1 ) ) {
		     this->value.data.logptr[elem] = 1;
		     this->value.undef[elem] = 0;
		  }
		  break;

	       case AND:
		  this->value.data.logptr[elem] = (val1 && val2);
		  break;

	       case EQ:
		  this->value.data.logptr[elem] = 
		     ( (val1 && val2) || (!val1 && !val2) );
		  break;

	       case NE:
		  this->value.data.logptr[elem] =
		     ( (val1 && !val2) || (!val1 && val2) );
		  break;
	       }
	    }
	    nelem = this->value.nelem;
	 }
      }
   }

   if( that1->operation>0 ) {
      free( that1->value.data.ptr );
      free( that1->value.undef );
   }
   if( that2->operation>0 ) {
      free( that2->value.data.ptr );
      free( that2->value.undef );
   }
}

static void Do_BinOp_lng( Node *this )
{
   Node *that1, *that2;
   int  vector1, vector2;
   long val1, val2;
   char null1, null2;
   long rows, nelem, elem;

   that1 = gParse.Nodes + this->SubNodes[0];
   that2 = gParse.Nodes + this->SubNodes[1];

   vector1 = ( that1->operation!=-1000 );
   if( vector1 )
      vector1 = that1->value.nelem;
   else {
      val1  = that1->value.data.lng;
      null1 = 0;
   }

   vector2 = ( that2->operation!=-1000 );
   if( vector2 )
      vector2 = that2->value.nelem;
   else {
      val2  = that2->value.data.lng;
      null2 = 0;
   }

   if( !vector1 && !vector2 ) {  /*  Result is a constant  */

      switch( this->operation ) {
      case '~':   /* Treat as == for LONGS */
      case EQ:    this->value.data.log = (val1 == val2);   break;
      case NE:    this->value.data.log = (val1 != val2);   break;
      case GT:    this->value.data.log = (val1 >  val2);   break;
      case LT:    this->value.data.log = (val1 <  val2);   break;
      case LTE:   this->value.data.log = (val1 <= val2);   break;
      case GTE:   this->value.data.log = (val1 >= val2);   break;

      case '+':   this->value.data.lng = (val1  + val2);   break;
      case '-':   this->value.data.lng = (val1  - val2);   break;
      case '*':   this->value.data.lng = (val1  * val2);   break;

      case '%':
	 if( val2 ) this->value.data.lng = (val1 % val2);
	 else       yyerror("Divide by Zero");
	 break;
      case '/': 
	 if( val2 ) this->value.data.lng = (val1 / val2); 
	 else       yyerror("Divide by Zero");
	 break;
      case POWER:
	 this->value.data.lng = (long)pow((double)val1,(double)val2);
	 break;
      }
      this->operation=-1000;

   } else {

      rows  = gParse.nRows;
      nelem = this->value.nelem;
      elem  = this->value.nelem * rows;

      Allocate_Ptrs( this );

      while( rows-- && !gParse.status ) {
	 while( nelem-- && !gParse.status ) {
	    elem--;

	    if( vector1>1 ) {
	       val1  = that1->value.data.lngptr[elem];
	       null1 = that1->value.undef[elem];
	    } else if( vector1 ) {
	       val1  = that1->value.data.lngptr[rows];
	       null1 = that1->value.undef[rows];
	    }

	    if( vector2>1 ) {
	       val2  = that2->value.data.lngptr[elem];
	       null2 = that2->value.undef[elem];
	    } else if( vector2 ) {
	       val2  = that2->value.data.lngptr[rows];
	       null2 = that2->value.undef[rows];
	    }

	    this->value.undef[elem] = (null1 || null2);
	    switch( this->operation ) {
	    case '~':   /* Treat as == for LONGS */
	    case EQ:   this->value.data.logptr[elem] = (val1 == val2);   break;
	    case NE:   this->value.data.logptr[elem] = (val1 != val2);   break;
	    case GT:   this->value.data.logptr[elem] = (val1 >  val2);   break;
	    case LT:   this->value.data.logptr[elem] = (val1 <  val2);   break;
	    case LTE:  this->value.data.logptr[elem] = (val1 <= val2);   break;
	    case GTE:  this->value.data.logptr[elem] = (val1 >= val2);   break;
	       
	    case '+':  this->value.data.lngptr[elem] = (val1  + val2);   break;
	    case '-':  this->value.data.lngptr[elem] = (val1  - val2);   break;
	    case '*':  this->value.data.lngptr[elem] = (val1  * val2);   break;

	    case '%':   
	       if( val2 ) this->value.data.lngptr[elem] = (val1 % val2);
	       else {
		  yyerror("Divide by Zero");
		  free( this->value.data.ptr );
		  free( this->value.undef );
	       }
	       break;
	    case '/': 
	       if( val2 ) this->value.data.lngptr[elem] = (val1 / val2); 
	       else {
		  yyerror("Divide by Zero");
		  free( this->value.data.ptr );
		  free( this->value.undef );
	       }
	       break;
	    case POWER:
	       this->value.data.lngptr[elem] = (long)pow((double)val1,(double)val2);
	       break;
	    }
	 }
	 nelem = this->value.nelem;
      }
   }

   if( that1->operation>0 ) {
      free( that1->value.data.ptr );
      free( that1->value.undef );
   }
   if( that2->operation>0 ) {
      free( that2->value.data.ptr );
      free( that2->value.undef );
   }
}

static void Do_BinOp_dbl( Node *this )
{
   Node   *that1, *that2;
   int    vector1, vector2;
   double val1, val2;
   char   null1, null2;
   long   rows, nelem, elem;

   that1 = gParse.Nodes + this->SubNodes[0];
   that2 = gParse.Nodes + this->SubNodes[1];

   vector1 = ( that1->operation!=-1000 );
   if( vector1 )
      vector1 = that1->value.nelem;
   else {
      val1  = that1->value.data.dbl;
      null1 = 0;
   }

   vector2 = ( that2->operation!=-1000 );
   if( vector2 )
      vector2 = that2->value.nelem;
   else {
      val2  = that2->value.data.dbl;
      null2 = 0;
   } 

   if( !vector1 && !vector2 ) {  /*  Result is a constant  */

      switch( this->operation ) {
      case '~':   this->value.data.log = ( fabs(val1-val2) < APPROX );   break;
      case EQ:    this->value.data.log = (val1 == val2);   break;
      case NE:    this->value.data.log = (val1 != val2);   break;
      case GT:    this->value.data.log = (val1 >  val2);   break;
      case LT:    this->value.data.log = (val1 <  val2);   break;
      case LTE:   this->value.data.log = (val1 <= val2);   break;
      case GTE:   this->value.data.log = (val1 >= val2);   break;

      case '+':   this->value.data.dbl = (val1  + val2);   break;
      case '-':   this->value.data.dbl = (val1  - val2);   break;
      case '*':   this->value.data.dbl = (val1  * val2);   break;

      case '%':
	 if( val2 ) this->value.data.dbl = val1 - val2*((int)(val1/val2));
	 else       yyerror("Divide by Zero");
	 break;
      case '/': 
	 if( val2 ) this->value.data.dbl = (val1 / val2); 
	 else       yyerror("Divide by Zero");
	 break;
      case POWER:
	 this->value.data.dbl = (double)pow(val1,val2);
	 break;
      }
      this->operation=-1000;

   } else {

      rows  = gParse.nRows;
      nelem = this->value.nelem;
      elem  = this->value.nelem * rows;

      Allocate_Ptrs( this );

      while( rows-- && !gParse.status ) {
	 while( nelem-- && !gParse.status ) {
	    elem--;

	    if( vector1>1 ) {
	       val1  = that1->value.data.dblptr[elem];
	       null1 = that1->value.undef[elem];
	    } else if( vector1 ) {
	       val1  = that1->value.data.dblptr[rows];
	       null1 = that1->value.undef[rows];
	    }

	    if( vector2>1 ) {
	       val2  = that2->value.data.dblptr[elem];
	       null2 = that2->value.undef[elem];
	    } else if( vector2 ) {
	       val2  = that2->value.data.dblptr[rows];
	       null2 = that2->value.undef[rows];
	    }

	    this->value.undef[elem] = (null1 || null2);
	    switch( this->operation ) {
	    case '~':   /* Treat as == for LONGS */
	    case EQ:    this->value.data.logptr[elem] = (val1 == val2);   break;
	    case NE:    this->value.data.logptr[elem] = (val1 != val2);   break;
	    case GT:    this->value.data.logptr[elem] = (val1 >  val2);   break;
	    case LT:    this->value.data.logptr[elem] = (val1 <  val2);   break;
	    case LTE:   this->value.data.logptr[elem] = (val1 <= val2);   break;
	    case GTE:   this->value.data.logptr[elem] = (val1 >= val2);   break;
	       
	    case '+':   this->value.data.dblptr[elem] = (val1  + val2);   break;
	    case '-':   this->value.data.dblptr[elem] = (val1  - val2);   break;
	    case '*':   this->value.data.dblptr[elem] = (val1  * val2);   break;

	    case '%':
	       if( val2 ) this->value.data.dblptr[elem] =
                                val1 - val2*((int)(val1/val2));
	       else {
		  yyerror("Divide by Zero");
		  free( this->value.data.ptr );
		  free( this->value.undef );
	       }
	       break;
	    case '/': 
	       if( val2 ) this->value.data.dblptr[elem] = (val1 / val2); 
	       else {
		  yyerror("Divide by Zero");
		  free( this->value.data.ptr );
		  free( this->value.undef );
	       }
	       break;
	    case POWER:
	       this->value.data.dblptr[elem] = (double)pow(val1,val2);
	       break;
	    }
	 }
	 nelem = this->value.nelem;
      }
   }

   if( that1->operation>0 ) {
      free( that1->value.data.ptr );
      free( that1->value.undef );
   }
   if( that2->operation>0 ) {
      free( that2->value.data.ptr );
      free( that2->value.undef );
   }
}

static void Do_Func( Node *this )
{
   Node *theParams[MAXSUBS];
   int  vector[MAXSUBS], allConst;
   lval pVals[MAXSUBS];
   char pNull[MAXSUBS];
   long   ival;
   double dval;
   int  i;
   long row, elem, nelem;

   i = this->nSubNodes;
   allConst = 1;
   while( i-- ) {
      theParams[i] = gParse.Nodes + this->SubNodes[i];
      vector[i]   = ( theParams[i]->operation!=-1000 );
      if( vector[i] ) {
	 allConst = 0;
	 vector[i] = theParams[i]->value.nelem;
      } else {
	 if( theParams[i]->type==DOUBLE ) {
	    pVals[i].data.dbl = theParams[i]->value.data.dbl;
	 } else if( theParams[i]->type==LONG ) {
	    pVals[i].data.lng = theParams[i]->value.data.lng;
	 } else if( theParams[i]->type==BOOLEAN ) {
	    pVals[i].data.log = theParams[i]->value.data.log;
	 } else
	    strcpy(pVals[i].data.str, theParams[i]->value.data.str);
	 pNull[i] = 0;
      }
   }

   if( this->nSubNodes==0 ) allConst = 0; /* These do produce scalars */

   if( allConst ) {

      switch( this->operation ) {

	 case sum_fct:
	    if( theParams[0]->type==BOOLEAN )
	       this->value.data.lng = ( pVals[0].data.log ? 1 : 0 );
	    else if( theParams[0]->type==LONG )
	       this->value.data.lng = pVals[0].data.lng;
	    else
	       this->value.data.dbl = pVals[0].data.dbl;
	    break;

	    /* Non-Trig single-argument functions */

	 case abs_fct:
	    if( theParams[0]->type==DOUBLE ) {
	       dval = pVals[0].data.dbl;
	       this->value.data.dbl = (dval>0.0 ? dval : -dval);
	    } else {
	       ival = pVals[0].data.lng;
	       this->value.data.lng = (ival> 0  ? ival : -ival);
	    }
	    break;

            /* Special Null-Handling Functions */

         case isnull_fct:  /* Constants are always defined */
	    this->value.data.log = 0;
	    break;
         case defnull_fct:
	    if( this->type==BOOLEAN )
	       this->value.data.log = pVals[0].data.log;
            else if( this->type==LONG )
	       this->value.data.lng = pVals[0].data.lng;
            else if( this->type==DOUBLE )
	       this->value.data.dbl = pVals[0].data.dbl;
            else if( this->type==STRING )
	       strcpy(this->value.data.str,pVals[0].data.str);
	    break;

	    /* Trig functions with 1 double argument */

	 case sin_fct:
	    this->value.data.dbl = sin( pVals[0].data.dbl );
	    break;
	 case cos_fct:
	    this->value.data.dbl = cos( pVals[0].data.dbl );
	    break;
	 case tan_fct:
	    this->value.data.dbl = tan( pVals[0].data.dbl );
	    break;
	 case asin_fct:
	    dval = pVals[0].data.dbl;
	    if( dval<-1.0 || dval>1.0 )
	       yyerror("Out of range argument to arcsin");
	    else
	       this->value.data.dbl = asin( dval );
	    break;
	 case acos_fct:
	    dval = pVals[0].data.dbl;
	    if( dval<-1.0 || dval>1.0 )
	       yyerror("Out of range argument to arccos");
	    else
	       this->value.data.dbl = acos( dval );
	    break;
	 case atan_fct:
	    dval = pVals[0].data.dbl;
	    this->value.data.dbl = atan( dval );
	    break;
	 case exp_fct:
	    dval = pVals[0].data.dbl;
	    this->value.data.dbl = exp( dval );
	    break;
	 case log_fct:
	    dval = pVals[0].data.dbl;
	    if( dval<=0.0 )
	       yyerror("Out of range argument to log");
	    else
	       this->value.data.dbl = log( dval );
	    break;
	 case log10_fct:
	    dval = pVals[0].data.dbl;
	    if( dval<=0.0 )
	       yyerror("Out of range argument to log10");
	    else
	       this->value.data.dbl = log10( dval );
	    break;
	 case sqrt_fct:
	    dval = pVals[0].data.dbl;
	    if( dval<0.0 )
	       yyerror("Out of range argument to sqrt");
	    else
	       this->value.data.dbl = sqrt( dval );
	    break;

	    /* Two-argument Trig Functions */

	 case atan2_fct:
	    this->value.data.dbl =
	       atan2( pVals[0].data.dbl, pVals[1].data.dbl );
	    break;

	    /* Boolean SAO region Functions... all arguments scalar dbls */

	 case near_fct:
	    this->value.data.log = near( pVals[0].data.dbl, pVals[1].data.dbl,
					 pVals[2].data.dbl );
	    break;
	 case circle_fct:
	    this->value.data.log = circle( pVals[0].data.dbl, pVals[1].data.dbl,
					   pVals[2].data.dbl, pVals[3].data.dbl,
					   pVals[4].data.dbl );
	    break;
	 case box_fct:
	    this->value.data.log = saobox( pVals[0].data.dbl, pVals[1].data.dbl,
					   pVals[2].data.dbl, pVals[3].data.dbl,
					   pVals[4].data.dbl, pVals[5].data.dbl,
					   pVals[6].data.dbl );
	    break;
	 case elps_fct:
	    this->value.data.log =
                               ellipse( pVals[0].data.dbl, pVals[1].data.dbl,
					pVals[2].data.dbl, pVals[3].data.dbl,
					pVals[4].data.dbl, pVals[5].data.dbl,
					pVals[6].data.dbl );
	    break;
      }
      this->operation = -1000;

   } else {

      Allocate_Ptrs( this );

      row  = gParse.nRows;
      elem = row * this->value.nelem;

      if( !gParse.status ) {
	 switch( this->operation ) {

	    /* Special functions with no arguments */

	 case row_fct:
	    while( row-- ) {
	       this->value.data.lngptr[row] = gParse.firstRow + row;
	       this->value.undef[row] = 0;
	    }
	    break;
	 case rnd_fct:
	    while( row-- ) {
	       this->value.data.dblptr[row] = (double)rand() / 2147483647; 
	       this->value.undef[row] = 0;
	    }
	    break;

	 case sum_fct:
	    elem = row * theParams[0]->value.nelem;
	    if( theParams[0]->type==BOOLEAN ) {
	       while( row-- ) {
		  this->value.data.lngptr[row] = 0;
		  this->value.undef[row] = 0;
		  nelem = theParams[0]->value.nelem;
		  while( nelem-- ) {
		     elem--;
		     this->value.data.lngptr[row] +=
			( theParams[0]->value.data.logptr[elem] ? 1 : 0 );
		     this->value.undef[row] |=
			  theParams[0]->value.undef[elem];
		  }
	       }		  
	    } else if( theParams[0]->type==LONG ) {
	       while( row-- ) {
		  this->value.data.lngptr[row] = 0;
		  this->value.undef[row] = 0;
		  nelem = theParams[0]->value.nelem;
		  while( nelem-- ) {
		     elem--;
		     this->value.data.lngptr[row] +=
			theParams[0]->value.data.lngptr[elem];
		     this->value.undef[row] |=
			  theParams[0]->value.undef[elem];
		  }
	       }		  
	    } else {
	       while( row-- ) {
		  this->value.data.dblptr[row] = 0.0;
		  this->value.undef[row] = 0;
		  nelem = theParams[0]->value.nelem;
		  while( nelem-- ) {
		     elem--;
		     this->value.data.dblptr[row] +=
			theParams[0]->value.data.dblptr[elem];
		     this->value.undef[row] |=
			  theParams[0]->value.undef[elem];
		  }
	       }		  
	    }
	    break;

	    /* Non-Trig single-argument functions */
	    
	 case abs_fct:
	    if( theParams[0]->type==DOUBLE )
	       while( elem-- ) {
		  dval = theParams[0]->value.data.dblptr[elem];
		  this->value.data.dblptr[elem] = (dval>0.0 ? dval : -dval);
		  this->value.undef[elem] = theParams[0]->value.undef[elem];
	       }
	    else
	       while( elem-- ) {
		  ival = theParams[0]->value.data.lngptr[elem];
		  this->value.data.lngptr[elem] = (ival> 0  ? ival : -ival);
		  this->value.undef[elem] = theParams[0]->value.undef[elem];
	       }
	    break;

            /* Special Null-Handling Functions */

	 case isnull_fct:
	    if( theParams[0]->type==STRING ) elem = row;
	    while( elem-- ) {
	       this->value.data.logptr[elem] = theParams[0]->value.undef[elem];
	       this->value.undef[elem] = 0;
	    }
	    break;
         case defnull_fct:
	    switch( this->type ) {
	    case BOOLEAN:
	       while( row-- ) {
		  nelem = this->value.nelem;
		  while( nelem-- ) {
		     elem--;
		     i=2; while( i-- )
			if( vector[i]>1 ) {
			   pNull[i] = theParams[i]->value.undef[elem];
			   pVals[i].data.log =
			      theParams[i]->value.data.logptr[elem];
			} else if( vector[i] ) {
			   pNull[i] = theParams[i]->value.undef[row];
			   pVals[i].data.log =
			      theParams[i]->value.data.logptr[row];
			}
		     if( pNull[0] ) {
			this->value.undef[elem] = pNull[1];
			this->value.data.logptr[elem] = pVals[1].data.log;
		     } else {
			this->value.undef[elem] = 0;
			this->value.data.logptr[elem] = pVals[0].data.log;
		     }
		  }
	       }
	       break;
	    case LONG:
	       while( row-- ) {
		  nelem = this->value.nelem;
		  while( nelem-- ) {
		     elem--;
		     i=2; while( i-- )
			if( vector[i]>1 ) {
			   pNull[i] = theParams[i]->value.undef[elem];
			   pVals[i].data.lng =
			      theParams[i]->value.data.lngptr[elem];
			} else if( vector[i] ) {
			   pNull[i] = theParams[i]->value.undef[row];
			   pVals[i].data.lng =
			      theParams[i]->value.data.lngptr[row];
			}
		     if( pNull[0] ) {
			this->value.undef[elem] = pNull[1];
			this->value.data.lngptr[elem] = pVals[1].data.lng;
		     } else {
			this->value.undef[elem] = 0;
			this->value.data.lngptr[elem] = pVals[0].data.lng;
		     }
		  }
	       }
	       break;
	    case DOUBLE:
	       while( row-- ) {
		  nelem = this->value.nelem;
		  while( nelem-- ) {
		     elem--;
		     i=2; while( i-- )
			if( vector[i]>1 ) {
			   pNull[i] = theParams[i]->value.undef[elem];
			   pVals[i].data.dbl =
			      theParams[i]->value.data.dblptr[elem];
			} else if( vector[i] ) {
			   pNull[i] = theParams[i]->value.undef[row];
			   pVals[i].data.dbl =
			      theParams[i]->value.data.dblptr[row];
			}
		     if( pNull[0] ) {
			this->value.undef[elem] = pNull[1];
			this->value.data.dblptr[elem] = pVals[1].data.dbl;
		     } else {
			this->value.undef[elem] = 0;
			this->value.data.dblptr[elem] = pVals[0].data.dbl;
		     }
		  }
	       }
	       break;
	    case STRING:
	       while( row-- ) {
		  i=2; while( i-- )
		     if( vector[i] ) {
			pNull[i] = theParams[i]->value.undef[row];
			strcpy(pVals[i].data.str,
			       theParams[i]->value.data.strptr[row]);
		     }
		  if( pNull[0] ) {
		     this->value.undef[elem] = pNull[1];
		     strcpy(this->value.data.strptr[elem],pVals[1].data.str);
		  } else {
		     this->value.undef[elem] = 0;
		     strcpy(this->value.data.strptr[elem],pVals[0].data.str);
		  }
	       }
	    }
	    break;

	    /* Trig functions with 1 double argument */

	 case sin_fct:
	    while( elem-- )
	       if( !(this->value.undef[elem] = theParams[0]->value.undef[elem]) ) {
		  this->value.data.dblptr[elem] = 
		     sin( theParams[0]->value.data.dblptr[elem] );
	       }
	    break;
	 case cos_fct:
	    while( elem-- )
	       if( !(this->value.undef[elem] = theParams[0]->value.undef[elem]) ) {
		  this->value.data.dblptr[elem] = 
		     cos( theParams[0]->value.data.dblptr[elem] );
	       }
	    break;
	 case tan_fct:
	    while( elem-- )
	       if( !(this->value.undef[elem] = theParams[0]->value.undef[elem]) ) {
		  this->value.data.dblptr[elem] = 
		     tan( theParams[0]->value.data.dblptr[elem] );
	       }
	    break;
	 case asin_fct:
	    while( elem-- )
	       if( !(this->value.undef[elem] = theParams[0]->value.undef[elem]) ) {
		  dval = theParams[0]->value.data.dblptr[elem];
		  if( dval<-1.0 || dval>1.0 ) {
		     yyerror("Out of range argument to arcsin");
		     break;
		  } else
		     this->value.data.dblptr[elem] = asin( dval );
	       }
	    break;
	 case acos_fct:
	    while( elem-- )
	       if( !(this->value.undef[elem] = theParams[0]->value.undef[elem]) ) {
		  dval = theParams[0]->value.data.dblptr[elem];
		  if( dval<-1.0 || dval>1.0 ) {
		     yyerror("Out of range argument to arccos");
		     break;
		  } else
		     this->value.data.dblptr[elem] = acos( dval );
	       }
	    break;
	 case atan_fct:
	    while( elem-- )
	       if( !(this->value.undef[elem] = theParams[0]->value.undef[elem]) ) {
		  dval = theParams[0]->value.data.dblptr[elem];
		  this->value.data.dblptr[elem] = atan( dval );
	       }
	    break;
	 case exp_fct:
	    while( elem-- )
	       if( !(this->value.undef[elem] = theParams[0]->value.undef[elem]) ) {
		  dval = theParams[0]->value.data.dblptr[elem];
		  this->value.data.dblptr[elem] = exp( dval );
	       }
	    break;
	 case log_fct:
	    while( elem-- )
	       if( !(this->value.undef[elem] = theParams[0]->value.undef[elem]) ) {
		  dval = theParams[0]->value.data.dblptr[elem];
		  if( dval<=0.0 ) {
		     yyerror("Out of range argument to log");
		     break;
		  } else
		     this->value.data.dblptr[elem] = log( dval );
	       }
	    break;
	 case log10_fct:
	    while( elem-- )
	       if( !(this->value.undef[elem] = theParams[0]->value.undef[elem]) ) {
		  dval = theParams[0]->value.data.dblptr[elem];
		  if( dval<=0.0 ) {
		     yyerror("Out of range argument to log10");
		     break;
		  } else
		     this->value.data.dblptr[elem] = log10( dval );
	       }
	    break;
	 case sqrt_fct:
	    while( elem-- )
	       if( !(this->value.undef[elem] = theParams[0]->value.undef[elem]) ) {
		  dval = theParams[0]->value.data.dblptr[elem];
		  if( dval<0.0 ) {
		     yyerror("Out of range argument to sqrt");
		     break;
		  } else
		     this->value.data.dblptr[elem] = sqrt( dval );
	       }
	    break;

	    /* Two-argument Trig Functions */
	    
	 case atan2_fct:
	    while( row-- ) {
	       nelem = this->value.nelem;
	       while( nelem-- ) {
		  elem--;
		  i=2; while( i-- )
		     if( vector[i]>1 ) {
			pVals[i].data.dbl =
			   theParams[i]->value.data.dblptr[elem];
			pNull[i] = theParams[i]->value.undef[elem];
		     } else if( vector[i] ) {
			pVals[i].data.dbl =
			   theParams[i]->value.data.dblptr[row];
			pNull[i] = theParams[i]->value.undef[row];
		     }
		  if( !(this->value.undef[elem] = (pNull[0] || pNull[1]) ) )
		     this->value.data.dblptr[elem] =
			atan2( pVals[0].data.dbl, pVals[1].data.dbl );
	       }
	    }
	    break;

	    /* Boolean SAO region Functions... all arguments scalar dbls */

	 case near_fct:
	    while( row-- ) {
	       this->value.undef[row] = 0;
	       i=3; while( i-- )
		  if( vector[i] ) {
		     pVals[i].data.dbl = theParams[i]->value.data.dblptr[row];
		     this->value.undef[row] |= theParams[i]->value.undef[row];
		  }
	       if( !(this->value.undef[row]) )
		  this->value.data.logptr[row] =
		     near( pVals[0].data.dbl, pVals[1].data.dbl,
			   pVals[2].data.dbl );
	    }
	    break;
	 case circle_fct:
	    while( row-- ) {
	       this->value.undef[row] = 0;
	       i=5; while( i-- )
		  if( vector[i] ) {
		     pVals[i].data.dbl = theParams[i]->value.data.dblptr[row];
		     this->value.undef[row] |= theParams[i]->value.undef[row];
		  }
	       if( !(this->value.undef[row]) )
		  this->value.data.logptr[row] =
		     circle( pVals[0].data.dbl, pVals[1].data.dbl,
			     pVals[2].data.dbl, pVals[3].data.dbl,
			     pVals[4].data.dbl );
	    }
	    break;
	 case box_fct:
	    while( row-- ) {
	       this->value.undef[row] = 0;
	       i=7; while( i-- )
		  if( vector[i] ) {
		     pVals[i].data.dbl = theParams[i]->value.data.dblptr[row];
		     this->value.undef[row] |= theParams[i]->value.undef[row];
		  }
	       if( !(this->value.undef[row]) )
		  this->value.data.logptr[row] =
		     saobox( pVals[0].data.dbl, pVals[1].data.dbl,
			     pVals[2].data.dbl, pVals[3].data.dbl,
			     pVals[4].data.dbl, pVals[5].data.dbl,
			     pVals[6].data.dbl );
	    }
	    break;
	 case elps_fct:
	    while( row-- ) {
	       this->value.undef[row] = 0;
	       i=7; while( i-- )
		  if( vector[i] ) {
		     pVals[i].data.dbl = theParams[i]->value.data.dblptr[row];
		     this->value.undef[row] |= theParams[i]->value.undef[row];
		  }
	       if( !(this->value.undef[row]) )
		  this->value.data.logptr[row] =
		     ellipse( pVals[0].data.dbl, pVals[1].data.dbl,
			      pVals[2].data.dbl, pVals[3].data.dbl,
			      pVals[4].data.dbl, pVals[5].data.dbl,
			      pVals[6].data.dbl );
	    }
	    break;
	 }
      }
   }

   i = this->nSubNodes;
   while( i-- ) {
      if( theParams[i]->operation>0 ) {
	 free( theParams[i]->value.undef );    /* Currently only numeric */
	 free( theParams[i]->value.data.ptr ); /* params allowed         */
      }
   }
}

static void Do_Deref( Node *this )
{
   Node *theVar, *theDims[MAXDIMS];
   int  isConst[MAXDIMS], allConst;
   long dimVals[MAXDIMS];
   int  i, nDims;
   long row, elem, dsize;

   theVar = gParse.Nodes + this->SubNodes[0];

   i = nDims = this->nSubNodes-1;
   allConst = 1;
   while( i-- ) {
      theDims[i] = gParse.Nodes + this->SubNodes[i+1];
      isConst[i] = ( theDims[i]->operation==-1000 );
      if( isConst[i] )
	 dimVals[i] = theDims[i]->value.data.lng;
      else
	 allConst = 0;
   }

   if( this->type==DOUBLE ) {
      dsize = sizeof( double );
   } else if( this->type==LONG ) {
      dsize = sizeof( long );
   } else if( this->type==BOOLEAN ) {
      dsize = sizeof( char );
   } else
      dsize = 0;

   Allocate_Ptrs( this );

   if( !gParse.status ) {

      if( allConst && theVar->value.naxis==nDims ) {

	 /* Dereference completely using constant indices */

	 elem = 0;
	 i    = nDims;
	 while( i-- ) {
	    if( dimVals[i]<1 || dimVals[i]>theVar->value.naxes[i] ) break;
	    elem = theVar->value.naxes[i]*elem + dimVals[i]-1;
	 }
	 if( i<0 ) {
	    for( row=0; row<gParse.nRows; row++ ) {
	       this->value.undef[row] = theVar->value.undef[elem];
	       if( this->type==DOUBLE )
		  this->value.data.dblptr[row] = 
		     theVar->value.data.dblptr[elem];
	       else if( this->type==LONG )
		  this->value.data.lngptr[row] = 
		     theVar->value.data.lngptr[elem];
	       else
		  this->value.data.logptr[row] = 
		     theVar->value.data.logptr[elem];
	       elem += theVar->value.nelem;
	    }
	 } else {
	    yyerror("Index out of range");
	    free( this->value.undef );
	    free( this->value.data.ptr );
	 }
	 
      } else if( allConst && nDims==1 ) {
	 
	 /* Reduce dimensions by 1, using a constant index */
	 
	 if( dimVals[0] < 1 ||
	     dimVals[0] > theVar->value.naxes[ theVar->value.naxis-1 ] ) {
	    yyerror("Index out of range");
	    free( this->value.undef );
	    free( this->value.data.ptr );
	 } else {
	    elem = this->value.nelem * (dimVals[0]-1);
	    for( row=0; row<gParse.nRows; row++ ) {
	       memcpy( this->value.undef + row*this->value.nelem,
		       theVar->value.undef + elem,
		       this->value.nelem * sizeof(char) );
	       memcpy( (char*)this->value.data.ptr
		       + row*dsize*this->value.nelem,
		       (char*)theVar->value.data.ptr + elem*dsize,
		       this->value.nelem * dsize );
	       elem += theVar->value.nelem;
	    }	       
	 }
      
      } else if( theVar->value.naxis==nDims ) {

	 /* Dereference completely using an expression for the indices */

	 for( row=0; row<gParse.nRows; row++ ) {

	    for( i=0; i<nDims; i++ ) {
	       if( !isConst[i] ) {
		  if( theDims[i]->value.undef[row] ) {
		     yyerror("Null encountered as vector index");
		     free( this->value.undef );
		     free( this->value.data.ptr );
		     break;
		  } else
		     dimVals[i] = theDims[i]->value.data.lngptr[row];
	       }
	    }
	    if( gParse.status ) break;

	    elem = 0;
	    i    = nDims;
	    while( i-- ) {
	       if( dimVals[i]<1 || dimVals[i]>theVar->value.naxes[i] ) break;
	       elem = theVar->value.naxes[i]*elem + dimVals[i]-1;
	    }
	    if( i<0 ) {
	       elem += row*theVar->value.nelem;
	       this->value.undef[row] = theVar->value.undef[elem];
	       if( this->type==DOUBLE )
		  this->value.data.dblptr[row] = 
		     theVar->value.data.dblptr[elem];
	       else if( this->type==LONG )
		  this->value.data.lngptr[row] = 
		     theVar->value.data.lngptr[elem];
	       else
		  this->value.data.logptr[row] = 
		     theVar->value.data.logptr[elem];
	    } else {
	       yyerror("Index out of range");
	       free( this->value.undef );
	       free( this->value.data.ptr );
	    }
	 }

      } else {

	 /* Reduce dimensions by 1, using a nonconstant expression */

	 for( row=0; row<gParse.nRows; row++ ) {

	    /* Index cannot be a constant */

	    if( theDims[0]->value.undef[row] ) {
	       yyerror("Null encountered as vector index");
	       free( this->value.undef );
	       free( this->value.data.ptr );
	       break;
	    } else
	       dimVals[0] = theDims[0]->value.data.lngptr[row];

	    if( dimVals[0] < 1 ||
		dimVals[0] > theVar->value.naxes[ theVar->value.naxis-1 ] ) {
	       yyerror("Index out of range");
	       free( this->value.undef );
	       free( this->value.data.ptr );
	    } else {
	       elem  = this->value.nelem * (dimVals[0]-1);
	       elem += row*theVar->value.nelem;
	       memcpy( this->value.undef + row*this->value.nelem,
		       theVar->value.undef + elem,
		       this->value.nelem * sizeof(char) );
	       memcpy( (char*)this->value.data.ptr
		       + row*dsize*this->value.nelem,
		       (char*)theVar->value.data.ptr + elem*dsize,
		       this->value.nelem * dsize );
	    }
	 }
      }
   }

   if( theVar->operation>0 ) {
      free( theVar->value.undef );
      free( theVar->value.data.ptr );
   }
   for( i=0; i<nDims; i++ )
      if( theDims[i]->operation>0 ) {
	 free( theDims[i]->value.undef );
	 free( theDims[i]->value.data.ptr );
      }
}

/*****************************************************************************/
/*  Utility routines which perform the calculations on bits and SAO regions  */
/*****************************************************************************/

#define myPI  3.1415926535897932385

static char bitlgte(char *bits1, int oper, char *bits2)
{
 int val1, val2, nextbit;
 char result;
 int i, l1, l2, length, ldiff;
 char stream[256];
 char chr1, chr2;

 l1 = strlen(bits1);
 l2 = strlen(bits2);
 if (l1 < l2)
   {
    length = l2;
    ldiff = l2 - l1;
    i=0;
    while( ldiff-- ) stream[i++] = '0';
    while( l1--    ) stream[i++] = *(bits1++);
    stream[i] = '\0';
    bits1 = stream;
   }
 else if (l2 < l1)
   {
    length = l1;
    ldiff = l1 - l2;
    i=0;
    while( ldiff-- ) stream[i++] = '0';
    while( l2--    ) stream[i++] = *(bits2++);
    stream[i] = '\0';
    bits2 = stream;
   }
 else
    length = l1;

 val1 = val2 = 0;
 nextbit = 1;

 while( length-- )
    {
     chr1 = bits1[length];
     chr2 = bits2[length];
     if ((chr1 != 'x')&&(chr1 != 'X')&&(chr2 != 'x')&&(chr2 != 'X'))
       {
        if (chr1 == '1') val1 += nextbit;
        if (chr2 == '1') val2 += nextbit;
        nextbit *= 2;
       }
    }
 result = 0;
 switch (oper)
       {
        case LT:
             if (val1 < val2) result = 1;
             break;
        case LTE:
             if (val1 <= val2) result = 1;
             break;
        case GT:
             if (val1 > val2) result = 1;
             break;
        case GTE:
             if (val1 >= val2) result = 1;
             break;
       }
 return (result);
}

static void bitand(char *result,char *bitstrm1,char *bitstrm2)
{
 int i, l1, l2, ldiff;
 char stream[256];
 char chr1, chr2;

 l1 = strlen(bitstrm1);
 l2 = strlen(bitstrm2);
 if (l1 < l2)
   {
    ldiff = l2 - l1;
    i=0;
    while( ldiff-- ) stream[i++] = '0';
    while( l1--    ) stream[i++] = *(bitstrm1++);
    stream[i] = '\0';
    bitstrm1 = stream;
   }
 else if (l2 < l1)
   {
    ldiff = l1 - l2;
    i=0;
    while( ldiff-- ) stream[i++] = '0';
    while( l2--    ) stream[i++] = *(bitstrm2++);
    stream[i] = '\0';
    bitstrm2 = stream;
   }
 while ( (chr1 = *(bitstrm1++)) ) 
    {
       chr2 = *(bitstrm2++);
       if ((chr1 == 'x') || (chr2 == 'x'))
          *result = 'x';
       else if ((chr1 == '1') && (chr2 == '1'))
          *result = '1';
       else
          *result = '0';
       result++;
    }
 *result = '\0';
}

static void bitor(char *result,char *bitstrm1,char *bitstrm2)
{
 int i, l1, l2, ldiff;
 char stream[256];
 char chr1, chr2;

 l1 = strlen(bitstrm1);
 l2 = strlen(bitstrm2);
 if (l1 < l2)
   {
    ldiff = l2 - l1;
    i=0;
    while( ldiff-- ) stream[i++] = '0';
    while( l1--    ) stream[i++] = *(bitstrm1++);
    stream[i] = '\0';
    bitstrm1 = stream;
   }
 else if (l2 < l1)
   {
    ldiff = l1 - l2;
    i=0;
    while( ldiff-- ) stream[i++] = '0';
    while( l2--    ) stream[i++] = *(bitstrm2++);
    stream[i] = '\0';
    bitstrm2 = stream;
   }
 while ( (chr1 = *(bitstrm1++)) ) 
    {
       chr2 = *(bitstrm2++);
       if ((chr1 == '1') || (chr2 == '1'))
          *result = '1';
       else if ((chr1 == '0') || (chr2 == '0'))
          *result = '0';
       else
          *result = 'x';
       result++;
    }
 *result = '\0';
}

static void bitnot(char *result,char *bits)
{
   int length;
   char chr;

   length = strlen(bits);
   while( length-- ) {
      chr = *(bits++);
      *(result++) = ( chr=='1' ? '0' : ( chr=='0' ? '1' : chr ) );
   }
   *result = '\0';
}

static char bitcmp(char *bitstrm1, char *bitstrm2)
{
 int i, l1, l2, ldiff;
 char stream[256];
 char chr1, chr2;

 l1 = strlen(bitstrm1);
 l2 = strlen(bitstrm2);
 if (l1 < l2)
   {
    ldiff = l2 - l1;
    i=0;
    while( ldiff-- ) stream[i++] = '0';
    while( l1--    ) stream[i++] = *(bitstrm1++);
    stream[i] = '\0';
    bitstrm1 = stream;
   }
 else if (l2 < l1)
   {
    ldiff = l1 - l2;
    i=0;
    while( ldiff-- ) stream[i++] = '0';
    while( l2--    ) stream[i++] = *(bitstrm2++);
    stream[i] = '\0';
    bitstrm2 = stream;
   }
 while( (chr1 = *(bitstrm1++)) )
    {
       chr2 = *(bitstrm2++);
       if ( ((chr1 == '0') && (chr2 == '1'))
	    || ((chr1 == '1') && (chr2 == '0')) )
	  return( 0 );
    }
 return( 1 );
}

static char near(double x, double y, double tolerance)
{
 if (fabs(x - y) < tolerance)
   return ( 1 );
 else
   return ( 0 );
}

static char saobox(double xcen, double ycen, double xwid, double ywid,
		   double rot,  double xcol, double ycol)
{
 double x0,y0,xprime,yprime,xmin,xmax,ymin,ymax,theta;

 theta = (rot / 180.0) * myPI;
 xprime = xcol - xcen;
 yprime = ycol - ycen;
 x0 =  xprime * cos(theta) + yprime * sin(theta);
 y0 = -xprime * sin(theta) + yprime * cos(theta);
 xmin = - 0.5 * xwid; xmax = 0.5 * xwid;
 ymin = - 0.5 * ywid; ymax = 0.5 * ywid;
 if ((x0 >= xmin) && (x0 <= xmax) && (y0 >= ymin) && (y0 <= ymax))
   return ( 1 );
 else
   return ( 0 );
}

static char circle(double xcen, double ycen, double rad,
		   double xcol, double ycol)
{
 double r2,dx,dy,dlen;

 dx = xcol - xcen;
 dy = ycol - ycen;
 dx *= dx; dy *= dy;
 dlen = dx + dy;
 r2 = rad * rad;
 if (dlen <= r2)
   return ( 1 );
 else
   return ( 0 );
}

static char ellipse(double xcen, double ycen, double xrad, double yrad,
		    double rot, double xcol, double ycol)
{
 double x0,y0,xprime,yprime,dx,dy,dlen,theta;

 theta = (rot / 180.0) * myPI;
 xprime = xcol - xcen;
 yprime = ycol - ycen;
 x0 =  xprime * cos(theta) + yprime * sin(theta);
 y0 = -xprime * sin(theta) + yprime * cos(theta);
 dx = x0 / xrad; dy = y0 / yrad;
 dx *= dx; dy *= dy;
 dlen = dx + dy;
 if (dlen <= 1.0)
   return ( 1 );
 else
   return ( 0 );
}

static void yyerror(char *s)
{
    char msg[80];

    if( !gParse.status ) gParse.status = PARSE_SYNTAX_ERR;

    strncpy(msg, s, 80);
    msg[79] = '\0';
    ffpmsg(msg);
}
