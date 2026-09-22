# The NUL-delimited projection that sf_jq_fields decodes. Include this module
# directly: reaching entry through another module fails to compile, because it
# calls field rather than standing alone.

def field: ., "\u0000";

def entry($key; $value): ($key | field), ($value | field);
