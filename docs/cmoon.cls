\NeedsTeXFormat{LaTeX2e}
\ProvidesClass{cmoon}[C. MOON Technical Documentation]
\LoadClass[a4paper,twoside]{article}

\pagenumbering{arabic}

\RequirePackage[T1]{fontenc}
\RequirePackage{fontspec}

\RequirePackage[pass,paperwidth=\paperwidth,paperheight=\paperheight]{geometry}
\RequirePackage[unicode,linktocpage]{hyperref}
\hypersetup{colorlinks,citecolor=MidnightBlue,urlcolor=MidnightBlue,linkcolor=MidnightBlue}
\RequirePackage[explicit]{titlesec}
\RequirePackage{titletoc}
\RequirePackage{parskip}
\RequirePackage{silence}

\RequirePackage[dvipsnames,table]{xcolor}
\RequirePackage{amsmath,amssymb}
\RequirePackage{graphicx,calc}
\RequirePackage{stfloats}
\RequirePackage{wrapfig}
\RequirePackage{units}
\RequirePackage{tikz}

\RequirePackage{changepage}
\RequirePackage{makecell}
\RequirePackage{multicol}
\RequirePackage{multirow}
\RequirePackage{array}
\RequirePackage{bookmark}
\RequirePackage{booktabs}
\RequirePackage{caption}
\RequirePackage{colortbl}
\RequirePackage{tabularx}

\WarningsOff[latex]
\tcbuselibrary{listings,skins,breakable}
\WarningsOn[latex]

\tikzset{
    exterior size/.style args={#1x#2}{%
        outer sep=auto,
        minimum width={#1-\pgflinewidth},
        minimum height={#2-\pgflinewidth}
    }
}
\graphicspath{{images/}}

\usepackage{fancyhdr}
\fancypagestyle{plain}{%
    \fancyhf{}
    \fancyfoot[C]{\texttt{\thepage}}
}
\pagestyle{plain}
