# Sincronizador Sábio — actualizações

Este repositório serve **só** para distribuir actualizações do Sincronizador
Sábio aos POS do grupo. Não contém dados, configurações nem segredos.

```
publicado/
  actualizacao.json        manifesto: versão, SHA-256 e tamanho de cada ficheiro
  actualizacao.json.sig    assinatura RSA-3072 / SHA-256 do manifesto
  ficheiros/               os ficheiros actualizáveis
```

Os POS só instalam uma versão se:

1. a assinatura do manifesto for válida para a chave pública instalada em cada
   POS (a chave privada nunca sai do PC de administração);
2. cada ficheiro tiver exactamente o SHA-256 e o tamanho do manifesto;
3. a versão for superior à instalada e não tiver sido rejeitada antes.

Alterar qualquer ficheiro aqui sem a chave privada faz com que os POS recusem
a actualização. Uma versão que falhe dois arranques é revertida sozinha.

O instalador, o arranque, a configuração do serviço, o executável e a chave
pública nunca são actualizados por esta via.
