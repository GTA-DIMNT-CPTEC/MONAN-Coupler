# mensagens-mudadas.sed: mensagens de config_read que mudaram de propósito.
#
# compara-config.bash aplica estas trocas à saída da versão de referência
# antes de compará-la com a da árvore de trabalho. Cada linha troca o texto
# antigo pelo novo; numa referência que já tem o texto novo, nada casa e
# nada muda. Uma linha nova aqui é uma mudança de mensagem anunciada no
# docs/CHANGELOG.md.
#
# R-FASE13-29 (chaves por modelo): as mensagens que citavam só as chaves
# lógicas passam a citar as chaves por modelo, com as antigas entre
# parênteses.
s/ERRO: use_docn=\.false\. (MOM6) exige use_med_to_mpas=\.true\.; o MOM6 nao exporta o contorno da atmosfera\./ERRO: ocn_model=mom6 (use_docn=.false.) exige atm_boundary=med (use_med_to_mpas=.true.); o MOM6 nao exporta o contorno da atmosfera./
s/ERRO: use_sis2_dynamic=\.true\. exige use_docn=\.false\. (SIS2 precisa do MOM6)\./ERRO: ice_model=sis2 (use_sis2_dynamic=.true.) exige ocn_model=mom6 (use_docn=.false.); o SIS2 precisa do MOM6./
s/ERRO: ice_pet_count > 0 exige use_sis2_dynamic=\.true\./ERRO: ice_pet_count > 0 exige um modelo de gelo (ice_model=sis2; chave antiga use_sis2_dynamic=.true.)./
s/seq_repro=\.true\. exige use_med_to_mpas=\.true\. e use_sis2_dynamic=\.true\.; ignorado\./seq_repro=.true. exige atm_boundary=med e ice_model=sis2; ignorado./
