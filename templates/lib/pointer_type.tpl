{################################################################}
{% if phase=="prepare" %}

  {% if argument|is_argument %}
      void* {{carg}};
  {% endif %}

  {% if argument|is_return %}
    void* c_retval;
  {% endif %}

{% endif %}

{################################################################}
{% if phase=="to_c" %}
    {% if typedef|getNth:2=="unsigned" %}
   {{carg}} = (void*)strtoull(curarg, &nextarg, 16);
    {% else %}
   {{carg}} = (void*)strtoll(curarg, &nextarg, 16);
    {% endif %}
{% endif %}

{################################################################}
{% if phase=="argument" %}
  {% if argument|is_argument %}
    ({{raw_type|discard_restrict}}){{carg}}
  {% else %}
    (void*)
  {% endif %}
{% endif %}

{################################################################}
{% if phase=="to_erl"%}
    forward = snprintf({{buffer}}, {{left}}, "%lx", (long){{carg}});
{% endif %}

{################################################################}
{# no cleanup phase #}
{################################################################}
{% if phase=="erlformat" %}
"~.16b "
{% endif %}
{################################################################}
{% if phase=="erlconvert" %}
list_to_integer(string:substr(R, 1, length(R)-1), 16)
{% endif %}
