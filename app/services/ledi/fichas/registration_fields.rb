# Seção do dicionário (config/ledi/registration_dictionaries.yml, chaves em
# snake_case) → atributos das structs Thrift, pelo `ledi:` de cada campo
# (o nome do IDL, que vale sobre a documentação — §15.5). Converte pelo tipo:
# data → epoch ms (meia-noite no fuso da cidade), nome → Ledi::Fichas::LediName,
# contagem → texto quando o IDL a declara string (nuComodos, nuMoradores,
# quantosAnimaisNoDomicilio). Campo sem destino nas structs dadas = erro de
# programação (o dicionário e o IDL andam juntos, guardados pelo
# registration_dictionaries_spec).
module Ledi
  module Fichas
    module RegistrationFields
      class UnknownField < StandardError; end

      module_function

      # fields: o Hash de campos (Dictionary.section ou o `fields` de um
      # object); values: o Hash da seção; targets: as classes Thrift que
      # recebem. Devolve { classe => { campo_idl => valor } }; objects ficam
      # de fora (quem monta decide onde vão).
      def split(fields, values, targets)
        result = targets.index_with { {} }
        values.to_h.each do |key, value|
          spec = fields.fetch(key.to_s) { raise UnknownField, key.to_s }
          next if value.nil? || spec["type"] == "object"

          name = spec.fetch("ledi")
          target = targets.find { |klass| field(klass, name) } or raise UnknownField, name
          result[target][name] = convert(spec, value, field(target, name))
        end
        result
      end

      # Uma struct da classe com os campos da seção; nil sem nenhum campo.
      def build(klass, fields, values)
        attrs = split(fields, values, [ klass ])[klass]
        attrs.empty? ? nil : klass.new(**attrs.symbolize_keys)
      end

      def epoch_ms(date) = (Date.iso8601(date.to_s).in_time_zone.to_f * 1000).to_i

      def field(klass, name) = klass::FIELDS.values.find { |f| f[:name] == name }

      def convert(spec, value, field)
        case spec.fetch("type")
        when "date" then epoch_ms(value)
        when "name" then LediName.call(value)
        when "count" then field[:type] == ::Thrift::Types::STRING ? value.to_s : value
        else value
        end
      end
      private_class_method :field, :convert
    end
  end
end
