resource "null_resource" "goodbye_world" {
    provisioner "local-exec" {
      command = "echo Goodbye World"
    }

    depends_on = ["null_resource.hello_world"]
}

resource "null_resource" "hello_world" {
    provisioner "local-exec" {
      command = "echo Hello World"
    }
}
