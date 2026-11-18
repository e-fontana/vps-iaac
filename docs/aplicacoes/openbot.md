# OpenBot

> **Resumo:** o [OpenBot](https://openbot.run) (agentes de IA persistentes, cada um com o seu espaço de trabalho e navegador) roda na VPS como servidor self-hosted, gerenciado pelo ArgoCD. Você o usa pelo app desktop, pelo celular ou por `openbot.run/app`.
> **Para quem:** quem vai instalar, atualizar ou diagnosticar o OpenBot. **Dificuldade:** intermediária.
> **Palavras-chave:** openbot, nightly-labs, agentes, ia, seccomp, user namespace, electron, chromium, seccomp-installer, openbot-env, openbot login, networkpolicy, apparmor.

## O que é e onde fica
- Namespace `openbot`. Um Deployment com **1 réplica** (estratégia `Recreate`) da imagem oficial `ghcr.io/nightly-labs/openbot` (arm64), com versão fixa.
- **Não tem endereço**: nem Service, nem Ingress, nem domínio. O OpenBot só faz conexões de saída (conta, provedores de IA, Signal/TURN) e o app chega até ele por elas.
- Dados em `/data`, num volume `local-path` (disco da VPS, **sem backup automático**): banco SQLite, chaveiro, espaços dos agentes e os logins dos provedores (`~/.claude`, `~/.codex`...).
- Código: `gitops/groups/workloads/openbot.yaml` (Application **automática**) e `gitops/manifests/openbot/`.
- Licença **PolyForm Noncommercial 1.0.0**: uso pessoal. Uso comercial exige licença da Nightly Labs.

### As peças
| Arquivo | O que faz | Onda |
|---|---|---|
| `namespace.yaml` | Cria a namespace `openbot` | -3 |
| `seccomp.json` (vira o ConfigMap `openbot-seccomp-<hash>`) | O perfil seccomp do OpenBot, já no formato do k3s | -2 |
| `seccomp-installer.yaml` | DaemonSet que copia o perfil para o nó, em `/var/lib/kubelet/seccomp/openbot/openbot.json` | -1 |
| `openbot.yaml` | O volume `openbot-data` e o Deployment | 0 |
| `networkpolicy.yaml` | Isola o pod do resto da VPS | 0 |

### Por que o perfil seccomp
O *seccomp* é a lista de chamadas ao kernel que um contêiner pode fazer. O sandbox do Electron/Chromium precisa criar *user namespaces*, que o perfil padrão bloqueia. O OpenBot publica um perfil próprio (o padrão do Docker com essa liberação); **nunca** troque por `Unconfined` nem por `privileged`.

O arquivo do projeto está no formato do Docker, com regras condicionais que o k3s ignora. Por isso o repositório guarda as duas versões:
- `templates/openbot/seccomp-docker.json`: o original, copiado da tag do OpenBot em uso.
- `gitops/manifests/openbot/seccomp.json`: o convertido por `templates/openbot/seccomp-docker-para-oci.py`, para arm64 e as capabilities padrão do contêiner (o que o Docker faria sozinho).

O kubelet só lê perfis do disco do nó; o DaemonSet `seccomp-installer` faz essa cópia a partir do Git (e de novo quando o perfil muda), e o ArgoCD só sobe o OpenBot depois dele.

### Segurança
Os agentes rodam com **acesso total dentro do contêiner, sem pedir confirmação** (comandos, arquivos, rede, navegador). Por isso:
- O pod não recebe o token da ServiceAccount nem as variáveis dos Services do cluster.
- A NetworkPolicy só deixa sair DNS e internet: bloqueia os pods e Services do cluster (Postgres, Redis, S3, API, Grafana, ArgoCD), a rede da Oracle (`10.0.0.0/16`), a VPN (`100.64.0.0/10`) e o metadata da instância (`169.254.169.254`). **Limite:** o IP público da VPS continua alcançável; hoje os serviços estão atrás da VPN, mas uma porta aberta na internet no Terraform também ficaria visível para os agentes.
- Todos os agentes compartilham o mesmo usuário (UID 1000): um agente consegue ler os arquivos e as chaves dos outros, inclusive as do Secret `openbot-env`.

## Instalar
1. **(Opcional) chaves de provedores.** Só para provedores que pedem chave de API (por exemplo o Grok, `XAI_API_KEY`). Claude Code, Codex e Gemini entram pelo próprio login, dentro do app. Num arquivo `openbot.env` no seu computador, uma por linha (`NOME=valor`), e:
   ```bash
   KUBECTL="ssh ubuntu@100.95.76.83 sudo k3s kubectl" bash templates/openbot/create-env-secret.sh < openbot.env
   ```
   Os valores não são impressos. Apague o `openbot.env` depois. Pode ser feito antes ou depois do push; se for depois, reinicie o pod (veja *Operação*).
2. **Commit e push** dos arquivos. A Application `openbot` é automática: o ArgoCD aplica sozinho, onda por onda.
3. **Login, uma vez** (o OpenBot manda um código para o seu e-mail; vale 10 minutos):
   ```bash
   ssh -t ubuntu@100.95.76.83 'sudo k3s kubectl -n openbot exec -it deploy/openbot -- openbot login'
   ```
   A sessão fica salva em `/data` e sobrevive a reinícios e a novos Syncs.
4. **Usar:** abra o app desktop, o app do celular ou [openbot.run/app](https://openbot.run/app) com a mesma conta e escolha este servidor. Para parear o celular por QR code (expira em 2 minutos):
   ```bash
   ssh -t ubuntu@100.95.76.83 'sudo k3s kubectl -n openbot exec -it deploy/openbot -- openbot mobile-connect'
   ```

## Como saber que deu certo
- No ArgoCD, a Application `openbot` fica `Synced` e `Healthy`.
- `ssh ubuntu@100.95.76.83 'sudo k3s kubectl -n openbot get pods,pvc'` mostra o `seccomp-installer-...` e o `openbot-...` em `Running` e o volume `Bound`.
- `ssh ubuntu@100.95.76.83 'sudo k3s kubectl -n openbot exec deploy/openbot -- openbot status'` mostra o servidor, a conta e a memória (`ok`, `low` ou `critical`).
- O servidor aparece no app com a mesma conta.

## Operação
- **Logs:** `ssh ubuntu@100.95.76.83 'sudo k3s kubectl -n openbot logs deploy/openbot --tail=100'` (ou o botão de logs no ArgoCD).
- **Reiniciar** (por exemplo, depois de criar ou trocar o `openbot-env`): `ssh ubuntu@100.95.76.83 'sudo k3s kubectl -n openbot rollout restart deploy/openbot'`. O OpenBot tem até 75 s para encerrar os agentes e fechar o banco.
- **Memória:** limite de 4 GiB (a VPS tem 12 GB). O OpenBot regula os turnos simultâneos pela memória livre (2 turnos até 5 GiB) e põe os novos na fila quando ela acaba. Para mais turnos, aumente o `limits.memory` em `openbot.yaml`, lembrando do resto da VPS.
- **Disco:** o volume usa o disco da VPS. Com o disco acima de 95%, o SeaweedFS para de gravar ([S3](../servicos/armazenamento-s3.md)); acompanhe o tamanho de `/data`: `ssh ubuntu@100.95.76.83 'sudo k3s kubectl -n openbot exec deploy/openbot -- du -sh /data'`.

## Atualizar
O OpenBot **nunca volta para uma versão mais antiga** com o mesmo `/data`: não faça downgrade da tag.
1. Veja a versão nova: `gh api repos/nightly-labs/openbot/releases/latest --jq .tag_name`.
2. Confirme que a imagem já existe para arm64 (o projeto publica a release antes da imagem): `docker manifest inspect ghcr.io/nightly-labs/openbot:<versão>`.
3. Atualize o perfil seccomp e compare o diff:
   ```bash
   curl -fsSL -o templates/openbot/seccomp-docker.json https://raw.githubusercontent.com/nightly-labs/openbot/v<versão>/docker/seccomp.json
   python3 templates/openbot/seccomp-docker-para-oci.py templates/openbot/seccomp-docker.json gitops/manifests/openbot/seccomp.json
   git diff templates/openbot gitops/manifests/openbot/seccomp.json
   ```
   Confira também se o `docker/compose.yaml` da tag nova mudou algo (memória compartilhada, tempo de parada, volumes).
4. **Backup antes:** pare o OpenBot e copie a pasta do volume no nó inteira (inclui o chaveiro). Veja abaixo.
5. Troque a tag em `openbot.yaml`, faça commit e push.

### Backup manual
Não há backup automático. Para copiar `/data` com o OpenBot parado:
```bash
ssh ubuntu@100.95.76.83 'sudo k3s kubectl -n openbot scale deploy/openbot --replicas=0'
ssh ubuntu@100.95.76.83 'sudo k3s kubectl get pv $(sudo k3s kubectl -n openbot get pvc openbot-data -o jsonpath={.spec.volumeName}) -o jsonpath={.spec.hostPath.path}{.spec.local.path}'
# copie essa pasta (sudo tar) para fora da VPS, depois:
ssh ubuntu@100.95.76.83 'sudo k3s kubectl -n openbot scale deploy/openbot --replicas=1'
```
Enquanto estiver com 0 réplicas, o ArgoCD (`selfHeal`) volta para 1 em instantes; para um backup demorado, desligue o sync automático da Application antes.

## Desinstalar
Apague `gitops/groups/workloads/openbot.yaml` e faça push: o ArgoCD (com `prune`) remove tudo, **inclusive o volume com os dados**. Faça o backup antes. O arquivo do perfil em `/var/lib/kubelet/seccomp/openbot/` fica no nó (inofensivo); apague-o à mão se quiser.

## Se der errado
| Sintoma | Causa provável |
|---|---|
| Pod `openbot` em `CreateContainerError` com `seccomp` / `cannot load seccomp profile` | O perfil não está no nó: veja se o pod `seccomp-installer` está `Running` e os logs do contêiner `install`. |
| O contêiner sai logo, e o log fala de *user namespace* ou *sandbox* | O kernel ou o AppArmor estão bloqueando user namespaces. Veja `sysctl kernel.apparmor_restrict_unprivileged_userns` no nó (Ubuntu 24.04) e a seção abaixo. Não troque o seccomp por `Unconfined`. |
| Pod em `OOMKilled` | Memória acima de 4 GiB (agentes + Chromium + `/dev/shm`). Aumente o limite ou rode menos agentes ao mesmo tempo. |
| O servidor não aparece no app | Falta o `openbot login`, ou foi feito com outra conta. Veja `openbot status`. |
| Um agente não alcança um serviço da VPS (Postgres, API pelo IP interno) | É a NetworkPolicy, de propósito. |
| Agente Codex com acesso "Workspace only" falha com `bwrap: Failed to make / slave` | Limite conhecido do OpenBot em contêiner: escolha *Ask first* ou *Full access* para esse agente. |
| `ImagePullBackOff` | A tag ainda não foi publicada no GHCR (o projeto publica a release antes da imagem). |

### Se o AppArmor bloquear user namespaces
No Ubuntu 23.10 ou mais novo, o AppArmor pode impedir user namespaces. O próprio projeto diz que esse caso **não foi testado**. As saídas, da mais segura para a menos:
1. Um perfil do AppArmor no nó que permita `userns` para o contêiner (configuração do host, fora do ArgoCD).
2. `appArmorProfile: {type: Unconfined}` no contêiner do OpenBot: desliga o AppArmor só para ele, mantendo o seccomp. É uma redução de isolamento: decida antes de aplicar.

## O que foi e o que não foi testado
- **Verificado:** a imagem `ghcr.io/nightly-labs/openbot:0.72.0` existe para `linux/arm64`; os manifests renderizam com `kubectl kustomize`; o perfil convertido libera `clone`, `unshare` e `chroot` e bloqueia `mount`, `bpf` e `setns`, como o Docker faria para esse contêiner; o script do Secret foi checado com `bash -n` e um `kubectl` falso.
- **Não testado:** nada disso rodou ainda no cluster. O projeto testou o OpenBot só no Docker (não em Kubernetes); o sandbox do Electron com o perfil seccomp do containerd, o AppArmor do Ubuntu 24.04, o `openbot login` em contêiner e a NetworkPolicy na prática ainda precisam ser confirmados no primeiro deploy.

## Veja também
- [Como o GitOps funciona](../gitops/como-funciona.md) · [Solução de problemas](../suporte/solucao-de-problemas.md) · [Glossário](../comecando/glossario.md)
- Documentação do projeto: [Docker](https://github.com/nightly-labs/openbot/blob/main/docs/docker.md) · [Servidor self-hosted](https://github.com/nightly-labs/openbot/blob/main/docs/self-hosted-server.md)
