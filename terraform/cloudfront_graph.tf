# CloudFront distribution for serving the incident graph HTML from S3
# Permanent URL, no presigning needed, only exposes graph/ prefix

resource "aws_cloudfront_origin_access_control" "graph" {
  name                              = "fis-chaos-graph"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "graph" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "FIS Chaos Incident Graph"

  origin {
    domain_name              = aws_s3_bucket.results.bucket_regional_domain_name
    origin_id                = "s3-graph"
    origin_access_control_id = aws_cloudfront_origin_access_control.graph.id
    origin_path              = "/graph"
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-graph"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Allow CloudFront OAC to read graph/ prefix from S3
resource "aws_s3_bucket_policy" "graph_cloudfront" {
  bucket = aws_s3_bucket.results.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.results.arn}/graph/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.graph.arn
        }
      }
    }]
  })
}

output "graph_url" {
  value       = "https://${aws_cloudfront_distribution.graph.domain_name}"
  description = "Permanent URL for the incident graph (auto-refreshes every 5 min)"
}
