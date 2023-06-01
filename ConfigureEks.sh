#!/bin/bash -xv

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output=text)
AMX_PPL_ENV=$1
AMX_PPL_CLUSTER_EKS=$2
AMX_APP_PREFIX=$3
AMX_PPL_NAMESPACE=$4
AMX_PPL_VPC_ID=$5
AMX_PPL_ECR_REPO=$6
AWS_REGION=$7
EKS_DEPLOYER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${AMX_PPL_CLUSTER_EKS}-iam-rol-eks-deployer"
EKS_ROLE_KUBECTL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/AMX-PPL-CB-EKS-KUBECTL-${ACCOUNT_ID}-${AWS_REGION}"
EKS_ROLE_BACKEND_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${AMX_PPL_CLUSTER_EKS}-${ACCOUNT_ID}-${AWS_REGION}"


CREDENTIALS=$(aws sts assume-role --role-arn ${EKS_ROLE_KUBECTL_ARN} --role-session-name amx-ppl-cc-admin)
export AWS_ACCESS_KEY_ID="$(echo ${CREDENTIALS} | jq -r '.Credentials.AccessKeyId')"
export AWS_SECRET_ACCESS_KEY="$(echo ${CREDENTIALS} | jq -r '.Credentials.SecretAccessKey')"
export AWS_SESSION_TOKEN=$(echo "${CREDENTIALS}" | jq -r '.Credentials.SessionToken')

aws eks update-kubeconfig            \
  --name ${AMX_PPL_CLUSTER_EKS}        \
  --role-arn ${EKS_DEPLOYER_ROLE_ARN} \
  --region ${AWS_REGION}

EksCheckRoleBackend=$(kubectl get cm aws-auth -n kube-system -o yaml | grep rolearn | grep ${AMX_PPL_CLUSTER_EKS}-${ACCOUNT_ID}-${AWS_REGION})
if [ "${EksCheckRoleBackend}" == "" ]
then
  ROLE="    - groups:\n      - system:masters\n      rolearn: ${EKS_ROLE_BACKEND_ARN}\n      username: codebuild-eks"
  kubectl get -n kube-system configmap/aws-auth -o yaml | awk "/mapRoles: \|/{print;print \"${ROLE}\";next}1" > /tmp/aws-auth-patch-backend.yml
  kubectl patch configmap/aws-auth -n kube-system --patch "$(cat /tmp/aws-auth-patch-backend.yml)"
fi

###############################
### Install AWS Load Controller
###############################
helm repo add eks https://aws.github.io/eks-charts
helm repo update
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master"
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.5/docs/install/iam_policy.json

AWSLoadBalancerControllerPolicy=$(aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy --output text 2> /dev/null | grep POLICY | awk '{print $2}')
if [ "${AWSLoadBalancerControllerPolicy}" == "" ]
then
  aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json
fi
rm -f iam_policy.json

ServiceAccountAWSALbController=$(kubectl get serviceaccounts aws-load-balancer-controller -n kube-system 2> /dev/null | grep -v "^NAME" | awk '{print $1}')
if [ "${ServiceAccountAWSALbController}" == "" ]
then
  eksctl create iamserviceaccount \
    --cluster=${AMX_PPL_CLUSTER_EKS} \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --role-name AmazonEKSLoadBalancerControllerRole \
    --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
    --override-existing-serviceaccounts \
    --region ${AWS_REGION} --approve
fi

AWSLoadBalancerControllerDeployment=$(kubectl get deployment aws-load-balancer-controller -n kube-system 2> /dev/null | grep -v "^NAME" | awk '{print $1}')
if [ "${AWSLoadBalancerControllerDeployment}" == "" ]
then
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
    --set clusterName=${AMX_PPL_CLUSTER_EKS} \
    --set region=${AWS_REGION} \
    --set vpcId=${AMX_PPL_CLUSTER_VPC} \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set image.repository=${AMX_PPL_ECR_REPO}/amazon/aws-load-balancer-controller
fi

kubectl get pods -A -o wide
kubectl get deployment -A -o wide
#kubectl top pods -A