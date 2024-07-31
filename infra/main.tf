terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.aws_region
}

variable "project_name" {
  description = "The name of the project"
  type        = string
  default     = "nextjs-tf-example"
}

variable "env" {
  description = "The environment of the project"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "The AWS region"
  type        = string
  default     = "us-east-2"
}

variable "nextjs_cpu_arch" {
  description = "The CPU architecture of the Next.js container"
  type        = string
  default     = "arm64"
}

resource "aws_vpc" "vpc" {
  cidr_block                       = "10.0.0.0/16"
  enable_dns_support               = true
  enable_dns_hostnames             = true
  assign_generated_ipv6_cidr_block = true
}

resource "aws_subnet" "public_subnet" {
  vpc_id                          = aws_vpc.vpc.id
  cidr_block                      = "10.0.0.0/20"
  ipv6_cidr_block                 = aws_vpc.vpc.ipv6_cidr_block
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true
  availability_zone               = "${var.aws_region}a"
}

resource "aws_subnet" "private_egress_subnet" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.80.0/20"
  map_public_ip_on_launch = false
  availability_zone       = "${var.aws_region}a"
}

resource "aws_subnet" "private_isolated_subnet" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.129.0/24"
  map_public_ip_on_launch = false
  availability_zone       = "${var.aws_region}a"
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_egress_only_internet_gateway" "eigw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route" "route_eigw" {
  route_table_id         = aws_vpc.vpc.main_route_table_id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.eigw.id
}

resource "aws_route" "route_igw" {
  route_table_id         = aws_vpc.vpc.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_ecr_repository" "ecr_repo" {
  name                 = "${var.project_name}-ecr-repo-${var.env}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

locals {
  nextjs_image_hash = md5(join(
    "",
    [
      join("", [for x in fileset("${path.module}", "../{public,app}/**") : filemd5(x)]),
      join("", [for x in fileset("${path.module}", "../{Dockerfile,package-lock.json,next.config.mjs}") : filemd5(x)])
    ]
  ))
}

resource "null_resource" "image" {
  triggers = {
    hash = "${local.nextjs_image_hash}"
  }

  provisioner "local-exec" {
    command = <<EOF
      aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${aws_ecr_repository.ecr_repo.repository_url}
      docker build --platform=linux/${var.nextjs_cpu_arch} -t ${aws_ecr_repository.ecr_repo.repository_url}:${local.nextjs_image_hash} ../
      docker push ${aws_ecr_repository.ecr_repo.repository_url}:${local.nextjs_image_hash}
    EOF
  }
}

data "aws_ecr_image" "latest" {
  repository_name = aws_ecr_repository.ecr_repo.name
  image_tag       = local.nextjs_image_hash
  depends_on      = [null_resource.image]
}

resource "aws_service_discovery_private_dns_namespace" "discovery_namespace" {
  vpc  = aws_vpc.vpc.id
  name = "${var.project_name}-${var.env}.internal"
}

resource "aws_ecs_cluster" "ecs_cluster" {
  name = "${var.project_name}-cluster-${var.env}"
  service_connect_defaults {
    namespace = aws_service_discovery_private_dns_namespace.discovery_namespace.arn
  }
}

resource "aws_ecs_cluster_capacity_providers" "ecs_cluster_capacity_providers" {
  cluster_name       = aws_ecs_cluster.ecs_cluster.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_security_group" "internal_service_sg" {
  vpc_id      = aws_vpc.vpc.id
  description = "Security group that may be used for allowing traffic between services in the environment."
}

resource "aws_security_group_rule" "internal_service_sg_egress" {
  security_group_id = aws_security_group.internal_service_sg.id
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  // Allow all IPv6 and IPv4 traffic
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks = ["::/0"]
}

resource "aws_apigatewayv2_api" "nextjs_api" {
  name          = "nextjs-api-${var.project_name}-${var.env}"
  protocol_type = "HTTP"
  # When using a custom domain name, you must set this to true
  # disable_execute_api_endpoint = true
}

resource "aws_apigatewayv2_stage" "nextjs_api_stage" {
  api_id      = aws_apigatewayv2_api.nextjs_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "nextjs_integration" {
  api_id                 = aws_apigatewayv2_api.nextjs_api.id
  connection_id          = aws_apigatewayv2_vpc_link.apigw_vpc_link.id
  connection_type        = "VPC_LINK"
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = aws_service_discovery_service.nextjs_service_discovery.arn
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "nextjs_route" {
  api_id    = aws_apigatewayv2_api.nextjs_api.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.nextjs_integration.id}"
}

resource "aws_apigatewayv2_vpc_link" "apigw_vpc_link" {
  name               = "${var.project_name}-nextjs-link-${var.env}"
  security_group_ids = [aws_security_group.internal_service_sg.id]
  subnet_ids         = [aws_subnet.public_subnet.id]
}

resource "aws_iam_role" "ecs_task_role" {
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "nextjs_task" {
  family                   = "${var.project_name}-nextjs-${var.env}"
  container_definitions    = <<DEFINITION
  [
    {
      "name": "nextjs-container",
      "image": "${aws_ecr_repository.ecr_repo.repository_url}:${data.aws_ecr_image.latest.image_tag}",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 3000,
          "hostPort": 3000
        }
      ],
      "linuxParameters": {
        "initProcessEnabled": true
      },
      "memory": 512,
      "cpu": 256
    }
  ]
  DEFINITION
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  memory                   = 512
  cpu                      = 256
  runtime_platform {
    cpu_architecture        = upper(var.nextjs_cpu_arch)
    operating_system_family = "LINUX"
  }
  execution_role_arn = aws_iam_role.ecs_task_role.arn
  depends_on = [ data.aws_ecr_image.latest ]
}


resource "aws_ecs_service" "nextjs_service" {
  name            = "${var.project_name}-nextjs"
  cluster         = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.nextjs_task.arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 50 # Using 50% ensures the service is available but makes rolling updates much faster

  # Cause the deployment to fail and rollback if the service is unable to stabilize
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = [aws_subnet.public_subnet.id] # Deploy the public subnet, bypassing the need for a NAT gateway
    assign_public_ip = true                          # Assign a public IP to the container for internet access
    security_groups  = [aws_security_group.nextjs_service_sg.id]
  }

  # Register the service with the service discovery namespace
  service_registries {
    registry_arn   = aws_service_discovery_service.nextjs_service_discovery.arn
    container_name = "nextjs-container"
    container_port = 3000
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}

resource "aws_service_discovery_service" "nextjs_service_discovery" {
  name = "dns.nextjs" # dns.nextjs.${var.project_name}-${var.env}.internal
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.discovery_namespace.id
    dns_records {
      ttl  = 60
      type = "A"
    }
    dns_records {
      ttl  = 60
      type = "AAAA"
    }
    dns_records {
      ttl  = 60
      type = "SRV"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_security_group" "nextjs_service_sg" {
  vpc_id = aws_vpc.vpc.id
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # Only allowing traffic in from the vpc link security group
    security_groups = [aws_security_group.internal_service_sg.id]
  }

  egress {
    from_port   = 0             # Allow any incoming port
    to_port     = 0             # Allow any outgoing port
    protocol    = "-1"          # Allow any outgoing protocol 
    # Allow all IPv6 and IPv4 traffic
    cidr_blocks = ["0.0.0.0/0"] 
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_cloudfront_distribution" "nextjs_cdn" {
  enabled = true
  is_ipv6_enabled = true
  origin {
    origin_id = "default"
    # Use the API gateway as the origin
    domain_name = "${aws_apigatewayv2_api.nextjs_api.id}.execute-api.${var.aws_region}.amazonaws.com"
    custom_origin_config {
      origin_keepalive_timeout = 60
      origin_read_timeout = 60
      origin_protocol_policy = "https-only"
      http_port = 80
      https_port = 443
      origin_ssl_protocols = ["TLSv1.2"]
    }
  }
  # This is the cheapest price class, targets the US, Canada, and Europe
  price_class = "PriceClass_100" 
  default_cache_behavior {
    allowed_methods =["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD"]
    target_origin_id = "default"
    viewer_protocol_policy = "redirect-to-https"
    cache_policy_id = aws_cloudfront_cache_policy.nextjs_cdn_cache_policy.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host_header.id
    compress = true # Compress response objects automatically
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

resource "aws_cloudfront_cache_policy" "nextjs_cdn_cache_policy" {
  name = "nextjs-cdn-cache-policy"
  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "all"
    }
    enable_accept_encoding_gzip = true
    enable_accept_encoding_brotli = true
  }  
  min_ttl = 0
  default_ttl = 0 # Force the CDN to always check the origin for the latest content unless a cache-control header is set
}

# When not using a custom domain name, ignore the host header. Otherwise you'd use
# the "AllViewerAndCloudFrontHeaders-2022-06" policy with ID "33f36d7e-f396-46d9-90e0-52428a34d9dc"
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host_header" {
  # See: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-origin-request-policies.html#managed-origin-request-policy-all-viewer-except-host-header
  id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
}