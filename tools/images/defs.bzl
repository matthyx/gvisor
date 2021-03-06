"""Image configuration.

Images can be generated by using the vm_image rule. For example,

  vm_image(
      name = "ubuntu",
      project = "...",
      family = "...",
      scripts = [
          "script.sh",
          "other.sh",
      ],
  )

This will always create an vm_image in the current default gcloud project. The
rule has a text file as its output containing the image name. This will enforce
serialization for all dependent rules.

Images are always named per the hash of all the hermetic input scripts. This
allows images to be memoized quickly and easily.

The vm_test rule can be used to execute a command remotely. For example,

  vm_test(
      name = "mycommand",
      image = ":myimage",
      targets = [":test"],
  )
"""

def _vm_image_impl(ctx):
    script_paths = []
    for script in ctx.files.scripts:
        script_paths.append(script.short_path)

    resolved_inputs, argv, runfiles_manifests = ctx.resolve_command(
        command = "USERNAME=%s ZONE=$(cat %s) IMAGE_PROJECT=%s IMAGE_FAMILY=%s %s %s > %s" %
                  (
                      ctx.attr.username,
                      ctx.files.zone[0].path,
                      ctx.attr.project,
                      ctx.attr.family,
                      ctx.executable.builder.path,
                      " ".join(script_paths),
                      ctx.outputs.out.path,
                  ),
        tools = [ctx.attr.builder] + ctx.attr.scripts,
    )

    ctx.actions.run_shell(
        tools = resolved_inputs,
        outputs = [ctx.outputs.out],
        progress_message = "Building image...",
        execution_requirements = {"local": "true"},
        command = argv,
        input_manifests = runfiles_manifests,
    )
    return [DefaultInfo(files = depset([ctx.outputs.out]))]

_vm_image = rule(
    attrs = {
        "builder": attr.label(
            executable = True,
            default = "//tools/images:builder",
            cfg = "host",
        ),
        "username": attr.string(default = "$(whoami)"),
        "zone": attr.label(
            default = "//tools/images:zone",
            cfg = "host",
        ),
        "family": attr.string(mandatory = True),
        "project": attr.string(mandatory = True),
        "scripts": attr.label_list(allow_files = True),
    },
    outputs = {
        "out": "%{name}.txt",
    },
    implementation = _vm_image_impl,
)

def vm_image(**kwargs):
    _vm_image(
        tags = [
            "local",
            "manual",
        ],
        **kwargs
    )

def _vm_test_impl(ctx):
    runner = ctx.actions.declare_file("%s-executer" % ctx.label.name)

    # Note that the remote execution case must actually generate an
    # intermediate target in order to collect all the relevant runfiles so that
    # they can be copied over for remote execution.
    runner_content = "\n".join([
        "#!/bin/bash",
        "export ZONE=$(cat %s)" % ctx.files.zone[0].short_path,
        "export USERNAME=%s" % ctx.attr.username,
        "export IMAGE=$(cat %s)" % ctx.files.image[0].short_path,
        "export SUDO=%s" % "true" if ctx.attr.sudo else "false",
        "%s %s" % (
            ctx.executable.executer.short_path,
            " ".join([
                target.files_to_run.executable.short_path
                for target in ctx.attr.targets
            ]),
        ),
        "",
    ])
    ctx.actions.write(runner, runner_content, is_executable = True)

    # Return with all transitive files.
    runfiles = ctx.runfiles(
        transitive_files = depset(transitive = [
            depset(target.data_runfiles.files)
            for target in ctx.attr.targets
            if hasattr(target, "data_runfiles")
        ]),
        files = ctx.files.executer + ctx.files.zone + ctx.files.image +
                ctx.files.targets,
        collect_default = True,
        collect_data = True,
    )
    return [DefaultInfo(executable = runner, runfiles = runfiles)]

_vm_test = rule(
    attrs = {
        "image": attr.label(
            mandatory = True,
            cfg = "host",
        ),
        "executer": attr.label(
            executable = True,
            default = "//tools/images:executer",
            cfg = "host",
        ),
        "username": attr.string(default = "$(whoami)"),
        "zone": attr.label(
            default = "//tools/images:zone",
            cfg = "host",
        ),
        "sudo": attr.bool(default = True),
        "machine": attr.string(default = "n1-standard-1"),
        "targets": attr.label_list(
            mandatory = True,
            allow_empty = False,
            cfg = "target",
        ),
    },
    test = True,
    implementation = _vm_test_impl,
)

def vm_test(
        installer = "//tools/installers:head",
        **kwargs):
    """Runs the given targets as a remote test.

    Args:
      installer: Script to run before all targets.
      **kwargs: All test arguments. Should include targets and image.
    """
    targets = kwargs.pop("targets", [])
    if installer:
        targets = [installer] + targets
    targets = [
    ] + targets
    _vm_test(
        tags = [
            "local",
            "manual",
        ],
        targets = targets,
        local = 1,
        **kwargs
    )
