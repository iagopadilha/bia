#!/bin/bash
set -e

REGION="us-east-1"
ACCOUNT_ID="235951409508"
ECR_REPO="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/bia"

# ─── 1. Escolha de ambiente ───────────────────────────────────────────────────
echo ""
echo "=== AMBIENTE ==="
echo "[1] Sem ALB  (cluster-bia / service-bia / task-def-bia)"
echo "[2] Com ALB  (cluster-bia-alb / service-bia-alb / task-def-bia-alb)"
read -rp "Escolha [1/2]: " ENV_CHOICE

case "$ENV_CHOICE" in
  1)
    CLUSTER="cluster-bia"
    SERVICE="service-bia"
    TASK_FAMILY="task-def-bia"
    ;;
  2)
    CLUSTER="cluster-bia-alb"
    SERVICE="service-bia-alb"
    TASK_FAMILY="task-def-bia-alb"
    ;;
  *)
    echo "Opção inválida."; exit 1 ;;
esac

echo "→ Ambiente: $CLUSTER / $SERVICE / $TASK_FAMILY"

# ─── 2. Escolha de ação ───────────────────────────────────────────────────────
echo ""
echo "=== AÇÃO ==="
echo "[1] Build + Deploy  (build da imagem com commit hash atual)"
echo "[2] Rollback        (escolher uma tag existente no ECR)"
read -rp "Escolha [1/2]: " ACTION_CHOICE

case "$ACTION_CHOICE" in
  1)
    # Build + push
    COMMIT_HASH=$(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null || echo "manual-$(date +%s)")
    IMAGE_TAG="$COMMIT_HASH"

    echo ""
    echo "=== BUILD ==="
    echo "→ Tag: $IMAGE_TAG"

    aws ecr get-login-password --region "$REGION" \
      | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

    docker build -t "$ECR_REPO:latest" -t "$ECR_REPO:$IMAGE_TAG" "$(dirname "$0")"

    docker push "$ECR_REPO:latest"
    docker push "$ECR_REPO:$IMAGE_TAG"
    echo "→ Push concluído: $ECR_REPO:$IMAGE_TAG"
    ;;
  2)
    # Listar tags disponíveis no ECR
    echo ""
    echo "=== TAGS DISPONÍVEIS NO ECR ==="
    mapfile -t TAGS < <(aws ecr describe-images \
      --repository-name bia \
      --region "$REGION" \
      --query 'sort_by(imageDetails, &imagePushedAt)[*].imageTags[0]' \
      --output text | tr '\t' '\n' | grep -v '^None$' | grep -v '^latest$' | tac)

    if [ ${#TAGS[@]} -eq 0 ]; then
      echo "Nenhuma tag encontrada no ECR."; exit 1
    fi

    for i in "${!TAGS[@]}"; do
      echo "[$((i+1))] ${TAGS[$i]}"
    done

    read -rp "Escolha a tag para rollback [1-${#TAGS[@]}]: " TAG_CHOICE
    IMAGE_TAG="${TAGS[$((TAG_CHOICE-1))]}"

    if [ -z "$IMAGE_TAG" ]; then
      echo "Tag inválida."; exit 1
    fi
    echo "→ Tag selecionada: $IMAGE_TAG"
    ;;
  *)
    echo "Opção inválida."; exit 1 ;;
esac

# ─── 3. Registrar nova task definition ───────────────────────────────────────
echo ""
echo "=== REGISTRANDO TASK DEFINITION ==="

CURRENT_TASK_DEF=$(aws ecs describe-task-definition \
  --task-definition "$TASK_FAMILY" \
  --region "$REGION" \
  --query 'taskDefinition' \
  --output json)

NEW_TASK_DEF=$(echo "$CURRENT_TASK_DEF" | python3 -c "
import json, sys
td = json.load(sys.stdin)
td['containerDefinitions'][0]['image'] = '$ECR_REPO:$IMAGE_TAG'
for key in ['taskDefinitionArn','revision','status','requiresAttributes',
            'compatibilities','registeredAt','registeredBy']:
    td.pop(key, None)
print(json.dumps(td))
")

NEW_REVISION=$(aws ecs register-task-definition \
  --region "$REGION" \
  --cli-input-json "$NEW_TASK_DEF" \
  --query 'taskDefinition.revision' \
  --output text)

echo "→ Registrada: $TASK_FAMILY:$NEW_REVISION (imagem: $ECR_REPO:$IMAGE_TAG)"

# ─── 4. Deploy no ECS ─────────────────────────────────────────────────────────
echo ""
echo "=== DEPLOY ==="

aws ecs update-service \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --task-definition "$TASK_FAMILY:$NEW_REVISION" \
  --region "$REGION" \
  --output json > /dev/null

echo "→ Service atualizado para $TASK_FAMILY:$NEW_REVISION"

# ─── 5. Aguardar steady state ─────────────────────────────────────────────────
echo ""
echo "=== AGUARDANDO STEADY STATE ==="
echo "→ Aguardando serviço estabilizar (timeout: 5 min)..."

aws ecs wait services-stable \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --region "$REGION"

echo ""
echo "✅ Deploy concluído!"
echo "   Ambiente : $CLUSTER"
echo "   Service  : $SERVICE"
echo "   Task Def : $TASK_FAMILY:$NEW_REVISION"
echo "   Imagem   : $ECR_REPO:$IMAGE_TAG"
