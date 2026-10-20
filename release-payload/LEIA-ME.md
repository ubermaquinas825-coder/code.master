# Ateliê de Arte para Windows

## Abrir no notebook

Requisitos: Windows 10 ou Windows 11, **64 bits (x64/Intel/AMD)**, aproximadamente 1 GB de espaço livre para abrir o aplicativo, além do espaço das suas imagens. A versão ARM não está incluída neste pacote.

1. Baixe `Atelie-de-Arte-Windows-x64.exe` e salve em uma pasta sua, como Documentos.
2. Dê dois cliques no arquivo e aguarde a primeira abertura. Ele prepara os componentes incluídos e abre uma janela própria do Ateliê de Arte.
3. Crie sua conta local na primeira utilização. Não existe conta ou senha padrão.

Não precisa instalar Node.js, npm, banco de dados nem executar comandos. Esta é uma versão portátil: não exige instalação como administrador nem cria serviço em segundo plano. Fechar o aplicativo encerra as ferramentas locais. Abra novamente pelo mesmo `.exe` sempre que quiser trabalhar. Não apague o executável enquanto o aplicativo estiver aberto.

O pacote não possui assinatura digital comercial. O Windows pode identificar o editor como desconhecido; confira a origem do arquivo e seu SHA-256 antes de decidir executá-lo. O arquivo `.exe.sha256` acompanha a entrega para verificação.

## O que funciona sem internet

Cadastro e login locais, projetos, biblioteca, recortes, vetorização SVG, ampliação por interpolação, remoção de fundo uniforme, lettering, mockups 2D/3D e exportações. Mockup 3D depende de WebGL e do driver gráfico do notebook; a opção 2D continua disponível.

Geração e reconstrução pela OpenAI precisam de internet e de uma chave e um modelo habilitados na sua conta. Não existe chave compartilhada embutida no executável. Os limites de cada ferramenta são os mesmos descritos no README do sistema. Os créditos do aplicativo são unidades internas; não representam pagamento à OpenAI.

## Configurar OpenAI pela janela

Abra **Aplicativo → Configurar OpenAI…**, informe o identificador do modelo de imagem e sua chave, e clique em **Salvar configuração**. Aguarde a atualização das ferramentas. Não é necessário editar `.env` nem abrir terminal. Conclua trabalhos em andamento antes de alterar a configuração.

A chave fica criptografada pela proteção do usuário do Windows. Ela não reaparece na tela nem é incluída nos arquivos exportados. Para substituí-la, cole outra chave; para manter, deixe o campo vazio; para apagar, marque a opção de remoção. A cobrança da API é feita separadamente pela OpenAI.

## Seus dados e backup

Os dados ficam em `%APPDATA%\Ateliê de Arte\`, separados do executável. O menu **Aplicativo → Abrir pasta dos meus dados** mostra a localização exata. A subpasta `data` contém o banco SQLite e as imagens. Assim, substituir o `.exe` por uma atualização não apaga seus projetos.

Para backup, feche o aplicativo e copie toda a pasta de dados para um local seguro. Para restaurar no mesmo usuário, feche o aplicativo antes de substituir os dados. A chave criptografada pertence ao usuário do Windows: em outro notebook ou usuário será preciso cadastrá-la novamente pelo menu OpenAI.

Contas criadas em outra instalação web não aparecem automaticamente no notebook. Esta versão usa armazenamento local e não sincroniza com nuvem. Cada conta começa com 100 créditos internos, conforme a versão web.

## Se não abrir

Confirme Windows x64, espaço livre e permissão de escrita no seu usuário. Não execute de dentro de outro ZIP: extraia o arquivo antes. Se aparecer erro de inicialização, feche e abra novamente. O registro `app.log`, disponível na pasta dos dados, ajuda no diagnóstico; ele não deve registrar a chave OpenAI.

## Para quem mantém o código

A geração do pacote exige o ambiente de desenvolvimento; **quem usa o `.exe` não executa estes passos**:

```bash
npm ci
npm run desktop:windows
```

O script compila a aplicação, instala o empacotador a partir de `desktop/package-lock.json`, verifica o SHA-256 do Node.js oficial para Windows e inclui as bibliotecas nativas Windows x64 do Sharp. Gera `release/windows/Atelie-de-Arte-Windows-x64.exe` e seu checksum. Electron abre uma janela isolada e inicia o backend com um Node.js separado incluído no pacote. O serviço escuta apenas `127.0.0.1`, em porta automática; nenhum servidor precisa ser iniciado pelo usuário.

O alvo é `portable` com execução como usuário. Não há instalador, atualização automática nem certificado de assinatura incluídos. O empacotamento pode ser feito em Linux; a execução nativa no Windows deve ser validada no notebook de destino.
