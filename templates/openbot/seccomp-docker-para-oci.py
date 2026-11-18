#!/usr/bin/env python3
"""Converte o perfil seccomp do OpenBot (formato do Docker) para o formato OCI que o k3s entende.

Uso (da raiz do repositório):
    python3 templates/openbot/seccomp-docker-para-oci.py \
        templates/openbot/seccomp-docker.json gitops/manifests/openbot/seccomp.json

Por que existe:
    O OpenBot publica docker/seccomp.json no formato do Docker (moby). Esse formato tem regras
    condicionais ("includes"/"excludes" por capability, arquitetura e versão do kernel) que o próprio
    Docker resolve na hora de criar o contêiner. O containerd do k3s lê perfis "Localhost" no formato
    OCI e IGNORA esses campos: sem esta conversão, uma regra como "mount só com CAP_SYS_ADMIN" viraria
    "mount sempre".

O que faz:
    Resolve as condições como o Docker faria para um contêiner arm64 (aarch64) com as capabilities
    padrão do Docker e do containerd (as mesmas do pod do OpenBot, que não remove nem acrescenta
    nenhuma) e grava só os campos do formato OCI. Não acessa a rede nem o cluster.

Quando rodar:
    A cada atualização do OpenBot: baixe o docker/seccomp.json da tag nova para
    templates/openbot/seccomp-docker.json, rode este script e compare o diff. Veja
    docs/aplicacoes/openbot.md, seção "Atualizar".

Desfazer: é só um arquivo gerado; volte-o com git.
"""
import json
import sys

# Arquitetura da VPS (Oracle Ampere) como o Go a nomeia (é o que o Docker compara em "arches").
ARCH = "arm64"
ARCH_SECCOMP = "SCMP_ARCH_AARCH64"

# Capabilities padrão de um contêiner no Docker e no containerd (CRI). O pod do OpenBot usa este
# conjunto. Se mudar o securityContext do pod, ajuste aqui e gere o perfil de novo.
CAPS = {
    "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FSETID", "CAP_FOWNER", "CAP_MKNOD", "CAP_NET_RAW",
    "CAP_SETGID", "CAP_SETUID", "CAP_SETFCAP", "CAP_SETPCAP", "CAP_NET_BIND_SERVICE",
    "CAP_SYS_CHROOT", "CAP_KILL", "CAP_AUDIT_WRITE",
}

# Ubuntu 24.04 usa o kernel 6.8 ou mais novo: toda regra "minKernel" do perfil (hoje, 4.8) vale.
KERNEL = (6, 8)


def versao(texto):
    return tuple(int(parte) for parte in texto.split("."))


def vale(regra):
    inc = regra.get("includes") or {}
    exc = regra.get("excludes") or {}
    if ARCH in (exc.get("arches") or []):
        return False
    if any(cap in CAPS for cap in (exc.get("caps") or [])):
        return False
    if inc.get("arches") and ARCH not in inc["arches"]:
        return False
    if inc.get("caps") and not all(cap in CAPS for cap in inc["caps"]):
        return False
    if inc.get("minKernel") and KERNEL < versao(inc["minKernel"]):
        return False
    return True


def main():
    if len(sys.argv) != 3:
        sys.exit("uso: seccomp-docker-para-oci.py <seccomp-docker.json> <saida.json>")
    with open(sys.argv[1], encoding="utf-8") as arquivo:
        docker = json.load(arquivo)

    arquiteturas = []
    for item in docker.get("archMap") or []:
        if item["architecture"] == ARCH_SECCOMP:
            arquiteturas = [item["architecture"], *(item.get("subArchitectures") or [])]
    if not arquiteturas:
        sys.exit(f"erro: {ARCH_SECCOMP} não está no archMap do perfil")

    syscalls = []
    for regra in docker["syscalls"]:
        if not vale(regra):
            continue
        nova = {"names": regra["names"], "action": regra["action"]}
        if "errnoRet" in regra:
            nova["errnoRet"] = regra["errnoRet"]
        if regra.get("args"):
            nova["args"] = regra["args"]
        syscalls.append(nova)

    oci = {"defaultAction": docker["defaultAction"]}
    if "defaultErrnoRet" in docker:
        oci["defaultErrnoRet"] = docker["defaultErrnoRet"]
    oci["architectures"] = arquiteturas
    oci["syscalls"] = syscalls

    with open(sys.argv[2], "w", encoding="utf-8") as arquivo:
        json.dump(oci, arquivo, indent=2, ensure_ascii=False)
        arquivo.write("\n")
    print(f"ok: {len(syscalls)} de {len(docker['syscalls'])} regras valem para {ARCH}; gravado em {sys.argv[2]}")


if __name__ == "__main__":
    main()
