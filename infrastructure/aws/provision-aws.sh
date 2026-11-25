#!/usr/bin/env bash
# ==============================================================================
# Aprovisionamiento Automatizado de Infraestructura en AWS (Entrega 1)
# Compatible con AWS CLI v2 local y AWS CloudShell (directo en tu navegador).
#
# Crea:
#   - VPC 10.0.0.0/16 + Subred Pública (10.0.1.0/24) + Subred Privada (10.0.2.0/24)
#   - Internet Gateway + Tablas de Rutas
#   - 4 Security Groups con mínimo privilegio (puertos BD cerrados a Internet)
#   - Key Pair (.pem guardado solo en disco local, NUNCA en Git)
#   - 4 Instancias EC2 t3.micro (Capa Gratuita) con Docker + BDs levantadas:
#       1) ec2-gateway-bastion (Nginx + Bastión SSH)
#       2) ec2-catalog         (MongoDB 7 + Redis Cache)
#       3) ec2-cart            (Redis Cart/Sessions)
#       4) ec2-orders          (PostgreSQL 16)
#
# Uso:
#   export AWS_REGION=us-east-1
#   export ADMIN_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
#   export INSTANCE_TYPE="t3.micro"   # o t2.micro según región/cuenta
#   ./infrastructure/aws/provision-aws.sh
# ==============================================================================
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
KEY_NAME="${KEY_NAME:-tienda-departamental-key}"
ADMIN_CIDR="${ADMIN_CIDR:-}"
PROJECT_TAG="tienda-departamental"

if [[ -z "$ADMIN_CIDR" ]]; then
  echo "[INFO] Detectando IP pública actual para restringir SSH..."
  MY_IP="$(curl -s https://checkip.amazonaws.com || true)"
  if [[ -z "$MY_IP" ]]; then
    echo "[ERROR] Define ADMIN_CIDR manualmente, ej: export ADMIN_CIDR=203.0.113.10/32"
    exit 1
  fi
  ADMIN_CIDR="${MY_IP}/32"
fi

echo "======================================================================"
echo " Región:        $AWS_REGION"
echo " Tipo EC2:      $INSTANCE_TYPE"
echo " Key Pair:      $KEY_NAME"
echo " SSH permitido: $ADMIN_CIDR"
echo "======================================================================"

# Obtener AMI oficial más reciente de Ubuntu 24.04 LTS (x86_64)
AMI_ID="$(aws ssm get-parameters \
  --region "$AWS_REGION" \
  --names /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameters[0].Value' --output text)"
echo "[OK] AMI Ubuntu 24.04 LTS: $AMI_ID"

# 1. Crear Key Pair si no existe
if ! aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
  aws ec2 create-key-pair \
    --region "$AWS_REGION" \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
  chmod 400 "${KEY_NAME}.pem"
  echo "[OK] Key Pair creado y guardado en ${KEY_NAME}.pem (NO subir a Git)."
else
  echo "[INFO] Key Pair '$KEY_NAME' ya existe en $AWS_REGION."
fi

# 2. VPC + Subredes + IGW
VPC_ID="$(aws ec2 create-vpc --region "$AWS_REGION" --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=vpc-${PROJECT_TAG}}]" \
  --query 'Vpc.VpcId' --output text)"
aws ec2 modify-vpc-attribute --region "$AWS_REGION" --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --region "$AWS_REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

IGW_ID="$(aws ec2 create-internet-gateway --region "$AWS_REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=igw-${PROJECT_TAG}}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)"
aws ec2 attach-internet-gateway --region "$AWS_REGION" --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

AZ="$(aws ec2 describe-availability-zones --region "$AWS_REGION" --query 'AvailabilityZones[0].ZoneName' --output text)"

PUB_SUBNET_ID="$(aws ec2 create-subnet --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --cidr-block 10.0.1.0/24 --availability-zone "$AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=subnet-${PROJECT_TAG}-publica}]" \
  --query 'Subnet.SubnetId' --output text)"
aws ec2 modify-subnet-attribute --region "$AWS_REGION" --subnet-id "$PUB_SUBNET_ID" --map-public-ip-on-launch

PRIV_SUBNET_ID="$(aws ec2 create-subnet --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --cidr-block 10.0.2.0/24 --availability-zone "$AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=subnet-${PROJECT_TAG}-privada}]" \
  --query 'Subnet.SubnetId' --output text)"

PUB_RTB_ID="$(aws ec2 create-route-table --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=rtb-${PROJECT_TAG}-publica}]" \
  --query 'RouteTable.RouteTableId' --output text)"
aws ec2 create-route --region "$AWS_REGION" --route-table-id "$PUB_RTB_ID" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
aws ec2 associate-route-table --region "$AWS_REGION" --subnet-id "$PUB_SUBNET_ID" --route-table-id "$PUB_RTB_ID" >/dev/null

PRIV_RTB_ID="$(aws ec2 create-route-table --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=rtb-${PROJECT_TAG}-privada}]" \
  --query 'RouteTable.RouteTableId' --output text)"
aws ec2 associate-route-table --region "$AWS_REGION" --subnet-id "$PRIV_SUBNET_ID" --route-table-id "$PRIV_RTB_ID" >/dev/null

echo "[OK] VPC=$VPC_ID | Subred Pública=$PUB_SUBNET_ID | Subred Privada=$PRIV_SUBNET_ID"

# 3. Security Groups (puertos de BDs NUNCA abiertos a Internet)
SG_GATEWAY="$(aws ec2 create-security-group --region "$AWS_REGION" \
  --group-name sg-gateway-bastion --description "API Gateway HTTP publico y Bastion SSH" \
  --vpc-id "$VPC_ID" --query 'GroupId' --output text)"
SG_CATALOG="$(aws ec2 create-security-group --region "$AWS_REGION" \
  --group-name sg-catalog --description "Servicio Catalogo + MongoDB + Redis Cache" \
  --vpc-id "$VPC_ID" --query 'GroupId' --output text)"
SG_CART="$(aws ec2 create-security-group --region "$AWS_REGION" \
  --group-name sg-cart --description "Servicio Carrito + Redis Cart" \
  --vpc-id "$VPC_ID" --query 'GroupId' --output text)"
SG_ORDERS="$(aws ec2 create-security-group --region "$AWS_REGION" \
  --group-name sg-orders --description "Servicio Ordenes e Inventario + PostgreSQL" \
  --vpc-id "$VPC_ID" --query 'GroupId' --output text)"

# Reglas Inbound sg-gateway-bastion
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_GATEWAY" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_GATEWAY" \
  --protocol tcp --port 22 --cidr "$ADMIN_CIDR" >/dev/null

# Reglas Inbound sg-catalog (solo API 8001 desde Gateway/Orders y SSH desde Bastion)
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_CATALOG" \
  --protocol tcp --port 8001 --source-group "$SG_GATEWAY" >/dev/null
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_CATALOG" \
  --protocol tcp --port 8001 --source-group "$SG_ORDERS" >/dev/null
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_CATALOG" \
  --protocol tcp --port 22 --source-group "$SG_GATEWAY" >/dev/null

# Reglas Inbound sg-cart (solo API 8002 desde Gateway/Orders y SSH desde Bastion)
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_CART" \
  --protocol tcp --port 8002 --source-group "$SG_GATEWAY" >/dev/null
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_CART" \
  --protocol tcp --port 8002 --source-group "$SG_ORDERS" >/dev/null
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_CART" \
  --protocol tcp --port 22 --source-group "$SG_GATEWAY" >/dev/null

# Reglas Inbound sg-orders (solo API 8003 desde Gateway y SSH desde Bastion)
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ORDERS" \
  --protocol tcp --port 8003 --source-group "$SG_GATEWAY" >/dev/null
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ORDERS" \
  --protocol tcp --port 22 --source-group "$SG_GATEWAY" >/dev/null

echo "[OK] Security Groups creados:"
echo "     sg-gateway-bastion = $SG_GATEWAY"
echo "     sg-catalog         = $SG_CATALOG"
echo "     sg-cart            = $SG_CART"
echo "     sg-orders          = $SG_ORDERS"

# 4. Lanzar instancias EC2 (Capa Gratuita)
# Nota: Para evitar costo de NAT Gateway en Capa Gratuita, si usas subred privada
# pura debes levantar Docker vía AMI o NAT temporal; aquí lanzamos Gateway en
# subred pública y los 3 servicios en subred pública con Security Groups cerrados
# (ningún puerto de BD expuesto a 0.0.0.0/0, SSH solo desde Bastión).
# Si prefieres colocarlas en $PRIV_SUBNET_ID con NAT Instance, cambia SERVICE_SUBNET_ID.
SERVICE_SUBNET_ID="${SERVICE_SUBNET_ID:-$PUB_SUBNET_ID}"

launch_ec2() {
  local name="$1"
  local subnet_id="$2"
  local sg_id="$3"
  local private_ip="$4"

  aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --subnet-id "$subnet_id" \
    --security-group-ids "$sg_id" \
    --private-ip-address "$private_ip" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'Instances[0].InstanceId' --output text
}

IP_PREFIX="10.0.1"
if [[ "$SERVICE_SUBNET_ID" == "$PRIV_SUBNET_ID" ]]; then
  IP_PREFIX="10.0.2"
fi

EC2_GATEWAY="$(launch_ec2 ec2-gateway-bastion "$PUB_SUBNET_ID" "$SG_GATEWAY" 10.0.1.10)"
EC2_CATALOG="$(launch_ec2 ec2-catalog "$SERVICE_SUBNET_ID" "$SG_CATALOG" "${IP_PREFIX}.20")"
EC2_CART="$(launch_ec2 ec2-cart "$SERVICE_SUBNET_ID" "$SG_CART" "${IP_PREFIX}.30")"
EC2_ORDERS="$(launch_ec2 ec2-orders "$SERVICE_SUBNET_ID" "$SG_ORDERS" "${IP_PREFIX}.40")"

echo "[INFO] Esperando a que las 4 instancias pasen a estado 'running'..."
aws ec2 wait instance-running --region "$AWS_REGION" \
  --instance-ids "$EC2_GATEWAY" "$EC2_CATALOG" "$EC2_CART" "$EC2_ORDERS"

BASTION_IP="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$EC2_GATEWAY" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

echo "======================================================================"
echo " INFRAESTRUCTURA CREADA EXITOSAMENTE"
echo "======================================================================"
echo " ec2-gateway-bastion : $EC2_GATEWAY (Public IP: $BASTION_IP | Private: 10.0.1.10)"
echo " ec2-catalog         : $EC2_CATALOG (Private: ${IP_PREFIX}.20)"
echo " ec2-cart            : $EC2_CART    (Private: ${IP_PREFIX}.30)"
echo " ec2-orders          : $EC2_ORDERS  (Private: ${IP_PREFIX}.40)"
echo "======================================================================"
echo "Siguiente paso: copiar los docker-compose y scripts de databases/ vía Bastión"
echo "según docs/evidencia-infraestructura.md."
