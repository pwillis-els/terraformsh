variable "file-name" {
  description = "A file to create in the local directory"
  type = string
  default = "foo.bar.txt"
}

variable "insert-value" {
  description = "Insert a value into a file"
  type = string
  default = "default"
}

resource "local_file" "foo" {
  content  = "foo:${var.insert-value}:bar"
  filename = "${path.module}/${var.file-name}"
}
