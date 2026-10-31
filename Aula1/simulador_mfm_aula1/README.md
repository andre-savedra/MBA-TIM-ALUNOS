# Aula 1 — pacote dos alunos

**Simulador Exchange + Swagger + Node-RED inicialmente vazio.** Não contém fluxo resolvido, Functions de resposta nem painel pronto.

## Preparar e iniciar

Requisito: Node.js 22 ou 24 LTS com npm. Abra o terminal nesta pasta (onde está package.json).

```sh
npm ci
```

Copie `.env.example` para `.env`, mantendo os valores fictícios. No Windows, não salvar como `.env.txt`. A instalação exige Internet/cache; depois, a execução e o Swagger são locais.

Terminal 1:
```sh
npm start
```
Terminal 2, nesta mesma pasta:
```sh
npm run nodered
```

- Controle: <http://127.0.0.1:3000>
- Swagger: <http://127.0.0.1:3000/docs>
- Node red: <http://127.0.0.1:1880>
- `/pratica1-alt` dashboard.
