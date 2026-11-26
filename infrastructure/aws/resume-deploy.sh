#!/usr/bin/env bash
# ==============================================================================
# Reanuda cloudshell-all-in-one.sh si se cortó al lanzar las EC2 (p. ej. por
# "PendingVerification" en cuentas nuevas). Reutiliza la VPC, subred y Security
# Groups existentes, lanza SOLO las instancias que falten con los user-data
# guardados en ~/tienda-ud/ y escribe ~/tienda-creds.txt y ~/.ssh/config.
# Uso (en CloudShell):  bash ~/resume-deploy.sh
# ==============================================================================
set -euo pipefail
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
KEY_NAME="${KEY_NAME:-tienda-departamental-key}"
PROJECT_TAG="tienda-departamental"
UD="${HOME}/tienda-ud"

VPC_ID="$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters Name=tag:Project,Values=$PROJECT_TAG --query 'Vpcs[0].VpcId' --output text)"
[[ "$VPC_ID" == "None" ]] && { echo "No hay VPC del proyecto: corre cloudshell-all-in-one.sh"; exit 1; }
PUB_SUBNET="$(aws ec2 describe-subnets --region "$AWS_REGION" --filters Name=vpc-id,Values=$VPC_ID Name=cidr-block,Values=10.0.1.0/24 --query 'Subnets[0].SubnetId' --output text)"
sg() { aws ec2 describe-security-groups --region "$AWS_REGION" --filters Name=vpc-id,Values=$VPC_ID Name=group-name,Values="$1" --query 'SecurityGroups[0].GroupId' --output text; }
AMI_ID="$(aws ssm get-parameters --region "$AWS_REGION" \
  --names /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameters[0].Value' --output text)"
echo "VPC=$VPC_ID | Subred pública=$PUB_SUBNET | AMI=$AMI_ID"

instance_id() {
  aws ec2 describe-instances --region "$AWS_REGION" \
    --filters Name=vpc-id,Values=$VPC_ID Name=tag:Name,Values="$1" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

ensure_node() {
  local name="$1" sgname="$2" ip="$3" ud="$4" id
  id="$(instance_id "$name")"
  if [[ "$id" != "None" ]]; then echo "$name ya existe: $id" >&2; echo "$id"; return; fi
  echo "Lanzando $name ($ip)..." >&2
  aws ec2 run-instances --region "$AWS_REGION" \
    --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --subnet-id "$PUB_SUBNET" \
    --security-group-ids "$(sg "$sgname")" --private-ip-address "$ip" \
    --user-data "file://${UD}/${ud}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'Instances[0].InstanceId' --output text
}

ID_GW="$(ensure_node ec2-gateway-bastion tienda-gateway-bastion 10.0.1.10 gateway.sh)"
ID_CAT="$(ensure_node ec2-catalog tienda-catalog 10.0.1.20 catalog.sh)"
ID_CART="$(ensure_node ec2-cart tienda-cart 10.0.1.30 cart.sh)"
ID_ORD="$(ensure_node ec2-orders tienda-orders 10.0.1.40 orders.sh)"

aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$ID_GW" "$ID_CAT" "$ID_CART" "$ID_ORD"
GW_PUB_IP="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$ID_GW" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

# Contraseñas: se leen de los user-data con que se lanzaron las instancias
MONGO_PASS="$(sed -n "s/.*MONGO_INITDB_ROOT_PASSWORD='\([^']*\)'.*/\1/p" "$UD/catalog.sh")"
REDIS_CACHE_PASS="$(sed -n "s/.*--requirepass '\([^']*\)'.*/\1/p" "$UD/catalog.sh")"
REDIS_CART_PASS="$(sed -n "s/.*--requirepass '\([^']*\)'.*/\1/p" "$UD/cart.sh")"
PG_PASS="$(sed -n "s/.*POSTGRES_PASSWORD='\([^']*\)'.*/\1/p" "$UD/orders.sh")"

cat > "${HOME}/tienda-creds.txt" <<CREDS
AWS_REGION=${AWS_REGION}
VPC_ID=${VPC_ID}
GW_PUB_IP=${GW_PUB_IP}
ID_GW=${ID_GW}
ID_CAT=${ID_CAT}
ID_CART=${ID_CART}
ID_ORD=${ID_ORD}
MONGO_PASS=${MONGO_PASS}
REDIS_CACHE_PASS=${REDIS_CACHE_PASS}
REDIS_CART_PASS=${REDIS_CART_PASS}
PG_PASS=${PG_PASS}
CREDS
chmod 600 "${HOME}/tienda-creds.txt"

mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
cat > "${HOME}/.ssh/config" <<SSHCFG
Host tienda-bastion ${GW_PUB_IP}
  HostName ${GW_PUB_IP}
  User ubuntu
  IdentityFile ${HOME}/${KEY_NAME}.pem
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
Host 10.0.1.*
  User ubuntu
  IdentityFile ${HOME}/${KEY_NAME}.pem
  ProxyJump tienda-bastion
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
SSHCFG
chmod 600 "${HOME}/.ssh/config"

echo "======================================================================"
echo " LISTO — 4 EC2 running. Bastión público: ${GW_PUB_IP}"
echo " Credenciales: ~/tienda-creds.txt | Llave: ~/${KEY_NAME}.pem"
echo "======================================================================"
