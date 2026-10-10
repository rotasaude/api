# app/services/clinical_documents/content/declaration.rb
# Declaração de comparecimento (spec §4; Parecer Cofen 44/2025; modelo do
# PEC): data do atendimento, chegada/saída (padrão: check-in e encerramento)
# ou período, unidade do atendimento, acompanhante opcional e, no papel da
# recepção, a matrícula de quem emite.
module ClinicalDocuments
  module Content
    module Declaration
      PERIODS = %w[morning afternoon full_day].freeze
      HHMM = /\A([01]\d|2[0-3]):[0-5]\d\z/

      module_function

      def call(input, attendance:)
        input = Input.hash(input)
        content = { "date" => attendance.checked_in_at.in_time_zone.to_date.iso8601 }
        if input.key?("period")
          return Input.invalid("period") unless PERIODS.include?(input["period"])
          return Input.invalid("period") if input.key?("arrived_at") || input.key?("left_at")

          content["period"] = input["period"]
        else
          arrived = input.fetch("arrived_at") { attendance.checked_in_at.in_time_zone.strftime("%H:%M") }
          left = input.fetch("left_at") { attendance.closed_at&.in_time_zone&.strftime("%H:%M") }
          return Input.invalid("arrived_at") unless arrived.is_a?(String) && arrived.match?(HHMM)
          return Input.invalid("left_at") unless left.nil? || (left.is_a?(String) && left.match?(HHMM) && left >= arrived)

          content.merge!("arrived_at" => arrived, "left_at" => left)
        end
        companion = Input.text(input["companion_name"], 3..120)
        return Input.invalid("companion_name") if companion == :invalid

        registration = Input.text(input["issuer_registration"], 1..30)
        return Input.invalid("issuer_registration") if registration == :invalid

        Result.ok(content: content.merge("unit_name" => attendance.health_unit.name, "companion_name" => companion,
                                         "issuer_registration" => registration).compact)
      end
    end
  end
end
