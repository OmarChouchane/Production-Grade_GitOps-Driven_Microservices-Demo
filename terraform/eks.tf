resource "aws_security_group" "add_sg_eks" {
  name   = "additional-eks-sg"
  vpc_id = module.vpc.vpc_id
  ingress {
    description     = "HTTPS from bastion host"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]
  }


  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "additional-eks-sg"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "terraform-cluster"
  kubernetes_version = "1.34"

  create_iam_role          = true
  iam_role_name            = "eksClusterRole"
  iam_role_use_name_prefix = false

  # KodeKloud does not grant Terraform permission to manage these optional resources.
  create_cloudwatch_log_group = false
  encryption_config           = null
  create_kms_key              = false
  attach_encryption_policy    = false


  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  # Optional
  endpoint_public_access = false

  # KodeKloud does not grant the caller eks:AssociateAccessPolicy.
  enable_cluster_creator_admin_permissions = false


  vpc_id                        = module.vpc.vpc_id
  subnet_ids                    = module.vpc.private_subnets
  additional_security_group_ids = [aws_security_group.add_sg_eks.id]

  eks_managed_node_groups = {
    example = {
      create_iam_role          = true
      iam_role_name            = "AmazonEKSNodeRole"
      iam_role_use_name_prefix = false
      # Starting on 1.30, AL2023 is the default AMI type for EKS managed node groups
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]

      min_size     = 2
      max_size     = 5
      desired_size = 2
    }
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

