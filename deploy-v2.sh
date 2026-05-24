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

    docker build -t "$ECR_REPO:$IMAGE_TAG" -t "$ECR_REPO:latest" "$(dirname "$0")"

    docker push "$ECR_REPO:$IMAGE_TAG"
    docker push "$ECR_REPO:latest"
    echo "→ Push concluído: $ECR_REPO:$IMAGE_TAG (+ latest)"
    ;;
  2)
    # Listar revisões da task def com a imagem que cada uma usa
    echo ""
    echo "=== REVISÕES DISPONÍVEIS ($TASK_FAMILY) ==="
    mapfile -t REVISIONS < <(aws ecs list-task-definitions \
      --family-prefix "$TASK_FAMILY" \
      --region "$REGION" \
      --sort DESC \
      --query 'taskDefinitionArns[]' \
      --output text | tr '\t' '\n')

    if [ ${#REVISIONS[@]} -eq 0 ]; then
      echo "Nenhuma revisão encontrada."; exit 1
    fi

    for i in "${!REVISIONS[@]}"; do
      REV_ARN="${REVISIONS[$i]}"
      REV_IMAGE=$(aws ecs describe-task-definition \
        --task-definition "$REV_ARN" \
        --region "$REGION" \
        --query 'taskDefinition.containerDefinitions[0].image' \
        --output text)
      REV_NUM=$(echo "$REV_ARN" | grep -oE '[0-9]+$')
      echo "[$((i+1))] revisão $REV_NUM → $REV_IMAGE"
    done

    read -rp "Escolha a revisão para rollback [1-${#REVISIONS[@]}]: " TAG_CHOICE
    ROLLBACK_ARN="${REVISIONS[$((TAG_CHOICE-1))]}"

    if [ -z "$ROLLBACK_ARN" ]; then
      echo "Opção inválida."; exit 1
    fi

    ROLLBACK_REV=$(echo "$ROLLBACK_ARN" | grep -oE '[0-9]+$')
    echo "→ Revisão selecionada: $TASK_FAMILY:$ROLLBACK_REV"

    # No rollback, reutiliza a revisão existente diretamente (sem criar nova)
    NEW_REVISION="$ROLLBACK_REV"
    ;;
  *)
    echo "Opção inválida."; exit 1 ;;
esac

# ─── 3. Registrar nova task definition (apenas no build+deploy) ───────────────
if [ "$ACTION_CHOICE" = "1" ]; then
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
fi

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

FINAL_IMAGE=$(aws ecs describe-task-definition \
  --task-definition "$TASK_FAMILY:$NEW_REVISION" \
  --region "$REGION" \
  --query 'taskDefinition.containerDefinitions[0].image' \
  --output text)

echo ""
echo "✅ Deploy concluído!"
echo "   Ambiente : $CLUSTER"
echo "   Service  : $SERVICE"
echo "   Task Def : $TASK_FAMILY:$NEW_REVISION"
echo "   Imagem   : $FINAL_IMAGE"
