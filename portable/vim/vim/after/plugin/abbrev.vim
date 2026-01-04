if exists("g:loaded_after_abbrev")
  finish
endif
let g:loaded_after_abbrev = 1

" --- Command-line abbreviations ---
cnoreabbrev <expr> term  (getcmdtype() == ':' && getcmdline() =~# '^term$')     ? 'Term'      : 'term'
cnoreabbrev <expr> make  (getcmdtype() == ':' && getcmdline() =~# '^make$')     ? 'Make'      : 'make'

" --- General English typos ---
Abolish teh the
Abolish adn and
Abolish untill until
Abolish wich which
Abolish becuase because
Abolish hense hence
Abolish alot a\ lot
Abolish lastest latest
Abolish betwen between
Abolish buisness business
Abolish calender calendar
Abolish cemetary cemetery
Abolish libary library
Abolish neccessary necessary
Abolish resouce{,s} resource{}
Abolish afterword{,s} afterward{}
Abolish delimeter{,s} delimiter{}
Abolish foriegn foreign
Abolish goverment government
Abolish gaurentee guarantee
Abolish occured occurred
Abolish practics practices

" --- Desperate / separate ---
Abolish {despa,sepe}rat{e,es,ed,ing,ely,ion,ions,or} {despe,sepa}rat{}

" --- Receive ---
Abolish reciev{e,es,ed,ing,er,ers} receiv{}
Abolish recieve{,s,d,ing,r,rs} receive{,s,d,ing,r,rs}

" --- Separate ---
Abolish seperat{e,es,ed,ing,ely,ion,ions} separat{}

" --- Accommodate ---
Abolish accomodat{e,es,ed,ing,ion,ions} accommodat{}

" --- Achieve ---
Abolish acheiv{e,es,ed,ing,er,ers,ement,ements} achiev{}

" --- Definite ---
Abolish defin{ate,et,it}ly definitely

" --- Occur ---
Abolish occur{ed,ing,ence,ences} occur{red,ring,rence,rences}

" --- Address ---
Abolish adress{,es,ed,ing} address{,es,ed,ing}

" --- Environment / argument ---
Abolish enviroment{,s} environment{,s}
Abolish arguement{,s} argument{,s}

" --- Interrupt / embarrass ---
Abolish interupt{,ed,ing,ion,ions} interrupt{,ed,ing,ion,ions}
Abolish embarass{,ed,ing,ment,ments} embarrass{,ed,ing,ment,ments}

" --- Occasion ---
Abolish occassion occasion
Abolish ocassion occasion
Abolish occassional{,ly} occasional{}
Abolish occassionally occasionally

" --- Programming typos ---
Abolish pritn print
Abolish funciton function
Abolish retunr return
Abolish lenght length
Abolish param{a,t,at}er parameter

" --- Additional typos ---
Abolish independan{t,ce} independen{t,ce}
Abolish wierd weird
Abolish priviledg{e,es,ed,ing} privileg{e,es,ed,ing}
Abolish maintainance maintenance
Abolish threshhold threshold
Abolish truely truly
Abolish accross across
Abolish usefull useful
Abolish seige siege
Abolish definate definite

" --- Families ---
Abolish recomend{,s,ed,ing,ation,ations} recommend{}
Abolish reccomend{,s,ed,ing,ation,ations} recommend{}
Abolish refer{ed,ing} referr{ed,ing}
Abolish dependanc{y,ies} dependenc{y,ies}
Abolish compatabilit{y,ies} compatibilit{y,ies}
Abolish extention{,s} extension{}
Abolish comming coming
Abolish gaurd guard
Abolish occurances occurrences

" --- Developer / doc typos ---
Abolish defualt default
Abolish udpate update
Abolish verison version
Abolish statment{,s} statement{}
Abolish contruct{,or,ors,ed,ing,ion,ions} construct{}
Abolish initaliz{e,ed,ing,ation} initializ{}
Abolish initiliz{e,ed,ing,ation} initializ{}

" --- Brand capitalization ---
Abolish Github GitHub
Abolish Javascript JavaScript
Abolish Typescript TypeScript
Abolish Postgresql PostgreSQL

" --- Check ---
Abolish cehck check
Abolish healtch health

Abolish cosnt const
Abolish funtion function
