//// <https://jsontypedef.com/>
////
//// <https://datatracker.ietf.org/doc/html/rfc8927>

//
//
// TODO: discriminator should be able to be nullable!
//
//

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

pub type RootSchema {
  RootSchema(definitions: List(#(String, Schema)), schema: Schema)
}

pub type Type {
  /// `true` or `false`
  Boolean
  /// JSON strings
  String
  /// JSON strings containing an RFC3339 timestamp
  Timestamp
  /// JSON numbers
  Float32
  /// JSON numbers
  Float64
  /// Whole JSON numbers that fit in a signed 8-bit integer
  Int8
  /// Whole JSON numbers that fit in an unsigned 8-bit integer
  Uint8
  /// Whole JSON numbers that fit in a signed 16-bit integer
  Int16
  /// Whole JSON numbers that fit in an unsigned 16-bit integer
  Uint16
  /// Whole JSON numbers that fit in a signed 32-bit integer
  Int32
  /// Whole JSON numbers that fit in an unsigned 32-bit integer
  Uint32
}

pub type Schema {
  /// Any value. The empty form is like a Java Object or TypeScript any.
  Empty
  /// A simple built-in type. The type form is like a Java or TypeScript
  /// primitive type.
  Type(nullable: Bool, metadata: List(#(String, Dynamic)), type_: Type)
  /// One of a fixed set of strings. The enum form is like a Java or TypeScript
  /// enum.
  Enum(
    nullable: Bool,
    metadata: List(#(String, Dynamic)),
    variants: List(String),
  )
  // The properties form is like a Java class or TypeScript interface.
  Properties(
    nullable: Bool,
    metadata: List(#(String, Dynamic)),
    schema: PropertiesSchema,
  )
  /// A sequence of some other form. The elements form is like a Java `List<T>`
  /// or TypeScript `T[]`.
  Elements(nullable: Bool, metadata: List(#(String, Dynamic)), schema: Schema)
  /// A dictionary with string keys and some form values. The values form is
  /// like a Java `Map<String, T>` or TypeScript `{ [key: string]: T}`.
  Values(nullable: Bool, metadata: List(#(String, Dynamic)), schema: Schema)
  /// The discriminator form is like a tagged union.
  Discriminator(tag: String, mapping: List(#(String, PropertiesSchema)))
  /// The ref form is for re-using schemas, usually so you can avoid repeating
  /// yourself.
  Ref(nullable: Bool, metadata: List(#(String, Dynamic)), name: String)
}

pub type PropertiesSchema {
  PropertiesSchema(
    properties: List(#(String, Schema)),
    optional_properties: List(#(String, Schema)),
    additional_properties: Bool,
  )
}

pub fn to_json(schema: RootSchema) -> Json {
  let properties = schema_to_json(schema.schema)
  let properties = case schema.definitions {
    [] -> properties
    definitions -> {
      let definitions =
        list.map(definitions, fn(definition) {
          #(definition.0, json.object(schema_to_json(definition.1)))
        })
      [#("definitions", json.object(definitions)), ..properties]
    }
  }

  json.object(properties)
}

fn properties_schema_to_json(schema: PropertiesSchema) -> List(#(String, Json)) {
  let props_json = fn(props: List(#(String, Schema))) {
    json.object(
      list.map(props, fn(property) {
        #(property.0, json.object(schema_to_json(property.1)))
      }),
    )
  }

  let PropertiesSchema(
    properties:,
    optional_properties:,
    additional_properties:,
  ) = schema

  let data = []

  let data = case additional_properties {
    False -> data
    _ -> [#("additionalProperties", json.bool(True)), ..data]
  }

  let data = case optional_properties {
    [] -> data
    p -> [#("optionalProperties", props_json(p)), ..data]
  }

  let data = case properties {
    [] -> data
    p -> [#("properties", props_json(p)), ..data]
  }

  data
}

fn schema_to_json(schema: Schema) -> List(#(String, Json)) {
  case schema {
    Empty -> []
    Ref(nullable:, metadata:, name:) ->
      [#("values", json.string(name))]
      |> add_nullable(nullable)
      |> add_metadata(metadata)
    Type(nullable:, metadata:, type_:) ->
      [#("type", type_to_json(type_))]
      |> add_nullable(nullable)
      |> add_metadata(metadata)
    Enum(nullable:, metadata:, variants:) ->
      [#("enum", json.array(variants, json.string))]
      |> add_nullable(nullable)
      |> add_metadata(metadata)
    Values(nullable:, metadata:, schema:) ->
      [#("values", json.object(schema_to_json(schema)))]
      |> add_nullable(nullable)
      |> add_metadata(metadata)
    Elements(nullable:, metadata:, schema:) ->
      [#("elements", json.object(schema_to_json(schema)))]
      |> add_nullable(nullable)
      |> add_metadata(metadata)
    Properties(nullable:, metadata:, schema:) ->
      properties_schema_to_json(schema)
      |> add_nullable(nullable)
      |> add_metadata(metadata)
    Discriminator(tag:, mapping:) -> discriminator_to_json(tag, mapping)
  }
}

fn type_to_json(t: Type) -> Json {
  json.string(case t {
    Boolean -> "boolean"
    Float32 -> "float32"
    Float64 -> "float64"
    Int16 -> "int16"
    Int32 -> "int32"
    Int8 -> "int8"
    String -> "string"
    Timestamp -> "timestamp"
    Uint16 -> "uint16"
    Uint32 -> "uint32"
    Uint8 -> "uint8"
  })
}

fn discriminator_to_json(
  tag: String,
  mapping: List(#(String, PropertiesSchema)),
) -> List(#(String, Json)) {
  let mapping =
    list.map(mapping, fn(variant) {
      #(variant.0, json.object(properties_schema_to_json(variant.1)))
    })
  [#("discriminator", json.string(tag)), #("mapping", json.object(mapping))]
}

pub fn decoder(data: Dynamic) -> Result(RootSchema, List(dynamic.DecodeError)) {
  dynamic.decode2(RootSchema, fn(_) { Ok([]) }, decode_schema)(data)
}

fn decode_schema(data: Dynamic) -> Result(Schema, List(dynamic.DecodeError)) {
  use data <- result.try(dynamic.dict(dynamic.string, dynamic.dynamic)(data))
  // TODO: metadata
  // TODO: nullable
  let decoder =
    key_decoder(data, "type", decode_type)
    |> result.lazy_or(fn() { key_decoder(data, "enum", decode_enum) })
    |> result.lazy_or(fn() { key_decoder(data, "ref", decode_ref) })
    |> result.lazy_or(fn() { key_decoder(data, "values", decode_values) })
    |> result.lazy_or(fn() { key_decoder(data, "elements", decode_elements) })
    |> result.lazy_or(fn() {
      key_decoder(data, "discriminator", decode_discriminator)
    })
    |> result.lazy_or(fn() {
      key_decoder(data, "properties", decode_properties)
    })
    |> result.lazy_or(fn() {
      key_decoder(data, "extraProperties", decode_properties)
    })
    |> result.lazy_or(fn() {
      key_decoder(data, "additionalProperties", decode_properties)
    })
    |> result.unwrap(fn() { decode_empty(data) })

  decoder()
}

fn key_decoder(
  dict: Dict(String, Dynamic),
  key: String,
  constructor: fn(Dynamic, Dict(String, Dynamic)) ->
    Result(t, List(dynamic.DecodeError)),
) -> Result(fn() -> Result(t, List(dynamic.DecodeError)), Nil) {
  case dict.get(dict, key) {
    Ok(value) -> Ok(fn() { constructor(value, dict) })
    Error(e) -> Error(e)
  }
}

fn decode_discriminator(
  tag: Dynamic,
  data: Dict(String, Dynamic),
) -> Result(Schema, List(dynamic.DecodeError)) {
  use tag <- result.try(dynamic.string(tag) |> push_path("discriminator"))
  use mapping <- result.try(case dict.get(data, "mapping") {
    Ok(mapping) -> Ok(mapping)
    Error(_) -> Error([dynamic.DecodeError("field", "nothing", ["mapping"])])
  })
  use properties <- result.try(
    decode_object_as_list(mapping, decode_properties_schema)
    |> push_path("mapping"),
  )
  Ok(Discriminator(tag:, mapping: properties))
}

fn decode_object_as_list(
  data: Dynamic,
  inner: dynamic.Decoder(t),
) -> Result(List(#(String, t)), List(dynamic.DecodeError)) {
  dynamic.dict(dynamic.string, inner)(data)
  |> result.map(dict.to_list)
}

fn decode_properties(
  _tag: Dynamic,
  data: Dict(String, Dynamic),
) -> Result(Schema, List(dynamic.DecodeError)) {
  use nullable <- result.try(get_nullable(data))
  use metadata <- result.try(get_metadata(data))
  dynamic.from(data)
  |> decode_properties_schema
  |> result.map(Properties(nullable, metadata, _))
}

fn decode_properties_schema(
  data: Dynamic,
) -> Result(PropertiesSchema, List(dynamic.DecodeError)) {
  let field = fn(name, data) {
    case dynamic.field(name, dynamic.dynamic)(data) {
      Ok(d) -> decode_object_as_list(d, decode_schema) |> push_path(name)
      Error(_) -> Ok([])
    }
  }
  dynamic.decode3(
    PropertiesSchema,
    field("properties", _),
    field("optionalProperties", _),
    fn(d) {
      case dynamic.field("additionalProperties", dynamic.dynamic)(d) {
        Ok(d) -> dynamic.bool(d) |> push_path("additionalProperties")
        Error(_) -> Ok(False)
      }
    },
  )(data)
}

fn decode_type(
  type_: Dynamic,
  data: Dict(String, Dynamic),
) -> Result(Schema, List(dynamic.DecodeError)) {
  use type_ <- result.try(dynamic.string(type_) |> push_path("type"))
  use nullable <- result.try(get_nullable(data))
  use metadata <- result.try(get_metadata(data))

  case type_ {
    "boolean" -> Ok(Type(nullable, metadata, Boolean))
    "float32" -> Ok(Type(nullable, metadata, Float32))
    "float64" -> Ok(Type(nullable, metadata, Float64))
    "int16" -> Ok(Type(nullable, metadata, Int16))
    "int32" -> Ok(Type(nullable, metadata, Int32))
    "int8" -> Ok(Type(nullable, metadata, Int8))
    "string" -> Ok(Type(nullable, metadata, String))
    "timestamp" -> Ok(Type(nullable, metadata, Timestamp))
    "uint16" -> Ok(Type(nullable, metadata, Uint16))
    "uint32" -> Ok(Type(nullable, metadata, Uint32))
    "uint8" -> Ok(Type(nullable, metadata, Uint8))
    _ -> Error([dynamic.DecodeError("Type", "String", ["type"])])
  }
}

fn decode_enum(
  type_: Dynamic,
  data: Dict(String, Dynamic),
) -> Result(Schema, List(dynamic.DecodeError)) {
  use nullable <- result.try(get_nullable(data))
  use metadata <- result.try(get_metadata(data))
  dynamic.list(dynamic.string)(type_)
  |> push_path("enum")
  |> result.map(Enum(nullable, metadata, _))
}

fn decode_ref(
  type_: Dynamic,
  data: Dict(String, Dynamic),
) -> Result(Schema, List(dynamic.DecodeError)) {
  use nullable <- result.try(get_nullable(data))
  use metadata <- result.try(get_metadata(data))
  dynamic.string(type_)
  |> push_path("ref")
  |> result.map(Ref(nullable, metadata, _))
}

fn decode_empty(
  data: Dict(String, Dynamic),
) -> Result(Schema, List(dynamic.DecodeError)) {
  case dict.size(data) {
    0 -> Ok(Empty)
    _ -> Error([dynamic.DecodeError("Schema", "Dict", [])])
  }
}

fn decode_values(
  values: Dynamic,
  data: Dict(String, Dynamic),
) -> Result(Schema, List(dynamic.DecodeError)) {
  use nullable <- result.try(get_nullable(data))
  use metadata <- result.try(get_metadata(data))
  decode_schema(values)
  |> push_path("values")
  |> result.map(Values(nullable, metadata, _))
}

fn decode_elements(
  elements: Dynamic,
  data: Dict(String, Dynamic),
) -> Result(Schema, List(dynamic.DecodeError)) {
  use nullable <- result.try(get_nullable(data))
  use metadata <- result.try(get_metadata(data))
  decode_schema(elements)
  |> push_path("elements")
  |> result.map(Elements(nullable, metadata, _))
}

fn push_path(
  result: Result(t, List(dynamic.DecodeError)),
  segment: String,
) -> Result(t, List(dynamic.DecodeError)) {
  result.map_error(result, list.map(_, fn(e) {
    dynamic.DecodeError(..e, path: [segment, ..e.path])
  }))
}

fn get_metadata(
  data: Dict(String, Dynamic),
) -> Result(List(#(String, Dynamic)), List(dynamic.DecodeError)) {
  case dict.get(data, "metadata") {
    Ok(data) ->
      dynamic.dict(dynamic.string, dynamic.dynamic)(data)
      |> result.map(dict.to_list)
      |> push_path("metadata")
    Error(_) -> Ok([])
  }
}

fn get_nullable(
  data: Dict(String, Dynamic),
) -> Result(Bool, List(dynamic.DecodeError)) {
  case dict.get(data, "nullable") {
    Ok(data) -> dynamic.bool(data) |> push_path("nullable")
    Error(_) -> Ok(False)
  }
}

fn metadata_value_to_json(data: Dynamic) -> Json {
  let decoder =
    dynamic.any([
      fn(a) { dynamic.string(a) |> result.map(json.string) },
      fn(a) { dynamic.int(a) |> result.map(json.int) },
      fn(a) { dynamic.float(a) |> result.map(json.float) },
    ])
  case decoder(data) {
    Ok(data) -> data
    Error(_) -> json.string(string.inspect(data))
  }
}

fn add_metadata(
  data: List(#(String, Json)),
  metadata: List(#(String, Dynamic)),
) -> List(#(String, Json)) {
  case metadata {
    [] -> data
    _ -> {
      let metadata =
        list.map(metadata, fn(metadata) {
          #(metadata.0, metadata_value_to_json(metadata.1))
        })
      [#("metadata", json.object(metadata)), ..data]
    }
  }
}

fn add_nullable(
  data: List(#(String, Json)),
  nullable: Bool,
) -> List(#(String, Json)) {
  case nullable {
    False -> data
    True -> [#("nullable", json.bool(True)), ..data]
  }
}

pub opaque type Generator {
  Generator(
    generate_decoders: Bool,
    generate_encoders: Bool,
    dynamic_used: Bool,
    option_used: Bool,
    dict_used: Bool,
    types: Dict(String, String),
    functions: Dict(String, String),
  )
}

pub fn codegen() -> Generator {
  Generator(
    dynamic_used: False,
    option_used: False,
    dict_used: False,
    generate_decoders: False,
    generate_encoders: False,
    types: dict.new(),
    functions: dict.new(),
  )
}

pub fn generate_encoders(gen: Generator, x: Bool) -> Generator {
  Generator(..gen, generate_encoders: x)
}

pub fn generate_decoders(gen: Generator, x: Bool) -> Generator {
  Generator(..gen, generate_decoders: x)
}

type Out {
  Out(src: String, type_name: String)
}

pub type CodegenError {
  CodegenError
}

pub fn generate(
  gen: Generator,
  schema: RootSchema,
) -> Result(String, CodegenError) {
  use gen <- result.try(gen_register(gen, "Data", schema.schema))
  use gen <- result.map(gen_add_decoder(gen, option.None, schema.schema))
  gen_to_string(gen)
}

fn gen_register(
  gen: Generator,
  name: String,
  schema: Schema,
) -> Result(Generator, CodegenError) {
  case schema {
    Empty -> Ok(gen)
    Ref(nullable:, ..) -> Ok(gen_register_nullable(gen, nullable))
    Type(nullable:, ..) -> Ok(gen_register_nullable(gen, nullable))
    Enum(nullable:, ..) -> Ok(gen_register_nullable(gen, nullable))

    Properties(schema:, nullable:, ..) -> {
      let gen = gen_register_nullable(gen, nullable)
      gen_register_properties(gen, name, schema)
    }

    Elements(nullable:, schema:, ..) -> {
      let gen = gen_register_nullable(gen, nullable)
      gen_register(gen, name <> "Element", schema)
    }

    Values(nullable:, schema:, ..) -> {
      let gen = gen_register_nullable(gen, nullable)
      let gen = Generator(..gen, dict_used: True)
      gen_register(gen, name <> "Value", schema)
    }

    Discriminator(tag: _, mapping:) -> {
      list.try_fold(mapping, gen, fn(gen, mapping) {
        gen_register_properties(gen, name <> mapping.0, mapping.1)
      })
    }
  }
}

fn gen_register_properties(
  gen: Generator,
  name: String,
  schema: PropertiesSchema,
) -> Result(Generator, CodegenError) {
  // TODO: check that all names are unique
  let PropertiesSchema(
    properties:,
    optional_properties:,
    additional_properties: _,
  ) = schema

  use gen <- result.try(
    list.try_fold(properties, gen, fn(gen, prop) {
      gen_register(gen, name <> prop.0, prop.1)
    }),
  )

  use gen <- result.try(
    list.try_fold(optional_properties, gen, fn(gen, prop) {
      let gen = Generator(..gen, option_used: True)
      gen_register(gen, name <> prop.0, prop.1)
    }),
  )

  Ok(gen)
}

fn gen_register_nullable(gen: Generator, nullable: Bool) -> Generator {
  case nullable {
    False -> gen
    True -> Generator(..gen, option_used: True)
  }
}

fn gen_add_decoder(
  gen: Generator,
  name: Option(String),
  schema: Schema,
) -> Result(Generator, CodegenError) {
  use out <- result.try(de_schema(gen, schema))
  let gen = Generator(..gen, dynamic_used: True)
  let src =
    "pub fn decode(data: dynamic.Dynamic) -> decode.Decoder("
    <> out.type_name
    <> ") {
  "
    <> out.src
    <> "
  |> decode.from(data)
}\n"

  let name = case name {
    option.Some(name) -> name <> "_decoder"
    option.None -> "decoder"
  }
  gen_add_function(gen, name, src)
}

fn gen_add_function(
  gen: Generator,
  name: String,
  body: String,
) -> Result(Generator, CodegenError) {
  // TODO: ensure function does not already exist
  let functions = dict.insert(gen.functions, name, body)
  Ok(Generator(..gen, functions:))
}

fn gen_add_type(
  gen: Generator,
  name: String,
  body: String,
) -> Result(Generator, CodegenError) {
  // TODO: ensure type does not already exist
  let types = dict.insert(gen.types, name, body)
  Ok(Generator(..gen, types:))
}

fn gen_definitions(
  gen: Generator,
  schema: RootSchema,
) -> Result(Generator, CodegenError) {
  Ok(gen)
}

fn gen_decoders(gen: Generator, schema: RootSchema) -> Generator {
  gen
}

fn gen_encoders(gen: Generator, schema: RootSchema) -> Generator {
  gen
}

fn gen_to_string(gen: Generator) -> String {
  let imp = fn(used, module) {
    case used {
      True -> ["import " <> module]
      False -> []
    }
  }

  let imports =
    [
      imp(gen.generate_decoders, "decode"),
      imp(gen.dict_used, "gleam/dict"),
      imp(gen.dynamic_used, "gleam/dynamic"),
      imp(gen.option_used, "gleam/option"),
    ]
    |> list.flatten
    |> string.join("\n")

  let defs = fn(items) {
    items
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(a) { a.1 })
    |> string.join("\n\n")
  }

  let block = fn(s) {
    case s {
      "" -> []
      _ -> [s]
    }
  }

  [block(imports), block(defs(gen.types)), block(defs(gen.functions))]
  |> list.flatten
  |> string.join("\n\n")
}

fn de_schema(gen: Generator, schema: Schema) -> Result(Out, CodegenError) {
  case schema {
    Discriminator(_, _) -> todo
    Elements(schema:, nullable:, metadata: _) ->
      de_elements(gen, schema, nullable)
    Empty -> Ok(Out("decode.dynamic", "dynamic.Dynamic"))
    Enum(_, _, _) -> todo
    Properties(nullable:, schema:, metadata: _) ->
      de_properties(gen, schema, nullable)
    Ref(_, _, _) -> todo
    Type(type_:, nullable:, metadata: _) -> Ok(de_type(type_, nullable))
    Values(schema:, nullable:, metadata: _) -> de_values(gen, schema, nullable)
  }
}

fn de_properties(
  gen: Generator,
  schema: PropertiesSchema,
  nullable: Bool,
) -> Result(Out, CodegenError) {
  let result = de_properties_schema(gen, schema)
  use Out(src:, type_name:) <- result.map(result)
  de_nullable(src, type_name, nullable)
}

fn de_properties_schema(
  gen: Generator,
  schema: PropertiesSchema,
) -> Result(Out, CodegenError) {
  let PropertiesSchema(
    properties:,
    optional_properties:,
    additional_properties: _,
  ) = schema
  todo
}

fn de_values(
  gen: Generator,
  schema: Schema,
  nullable: Bool,
) -> Result(Out, CodegenError) {
  use Out(src:, type_name:) <- result.map(de_schema(gen, schema))
  let type_name = "dict.Dict(String, " <> type_name <> ")"
  let src = "decode.dict(decode.string, " <> src <> ")"
  de_nullable(src, type_name, nullable)
}

fn de_elements(
  gen: Generator,
  schema: Schema,
  nullable: Bool,
) -> Result(Out, CodegenError) {
  use Out(src:, type_name:) <- result.map(de_schema(gen, schema))
  let type_name = "List(" <> type_name <> ")"
  let src = "decode.list(" <> src <> ")"
  de_nullable(src, type_name, nullable)
}

fn de_type(t: Type, nullable: Bool) -> Out {
  let #(src, type_name) = case t {
    Boolean -> #("decode.bool", "Bool")
    Float32 | Float64 -> #("decode.float", "Float")
    String | Timestamp -> #("decode.string", "String")
    Int16 | Int32 | Int8 | Uint16 | Uint32 | Uint8 -> #("decode.int", "Int")
  }
  de_nullable(src, type_name, nullable)
}

fn de_nullable(src: String, type_name: String, nullable: Bool) -> Out {
  case nullable {
    True -> {
      let type_name = "option.Option(" <> type_name <> ")"
      let src = "decode.nullable(" <> src <> ")"
      Out(src:, type_name:)
    }
    False -> Out(src:, type_name:)
  }
}
