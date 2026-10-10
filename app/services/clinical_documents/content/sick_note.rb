# app/services/clinical_documents/content/sick_note.rb
# Atestado (spec §4; CFM 1.658/2002 art. 3º): afastamento (dias e início) ou
# acompanhante (nome, parentesco, motivo da CLT art. 473 X/XI/XII). CID só com
# autorização expressa do paciente (registrada no documento); acompanhante
# nunca com CID.
module ClinicalDocuments
  module Content
    module SickNote
      TYPES = %w[leave companion].freeze
      COMPANION_REASONS = %w[clt_473_x clt_473_xi clt_473_xii other].freeze
      COMPANION_KEYS = %w[companion_name companion_kinship companion_reason].freeze
      MAX_DAYS = 365
      BACKDATE_DAYS = 30

      module_function

      def call(input, today: Time.zone.today)
        input = Input.object(input)
        return Input.invalid("type") unless TYPES.include?(input["type"])
        return Input.invalid("cid_authorized") unless [ nil, true, false ].include?(input["cid_authorized"])

        note = Input.text(input["note"], 1..500)
        return Input.invalid("note") if note == :invalid

        input["type"] == "leave" ? leave(input, note, today) : companion(input, note, today)
      end

      def leave(input, note, today)
        extra = COMPANION_KEYS.find { |key| input.key?(key) }
        return Input.invalid(extra) if extra

        days = input["days"]
        return Input.invalid("days") unless days.is_a?(Integer) && days.between?(1, MAX_DAYS)

        start_on = start_date(input, today, today)
        return Input.invalid("start_on") unless start_on

        authorized = input["cid_authorized"] == true
        cid = nil
        unless input["cid10"].nil?
          return Result.fail(:cid_requires_authorization) unless authorized

          code = input["cid10"].is_a?(Hash) ? input["cid10"]["code"] : nil
          found = code.is_a?(String) ? ClinicalTerms.find("cid10", code) : nil
          return Input.invalid("cid10") unless found

          cid = { "code" => found.code, "label" => found.label }
        end
        content = { "type" => "leave", "days" => days, "start_on" => start_on.iso8601, "cid10" => cid,
                    "cid_authorized" => authorized }.compact
        Result.ok(content: content.merge("note" => note))
      end

      def companion(input, note, today)
        return Result.fail(:companion_cid_not_allowed) unless input["cid10"].nil?
        return Input.invalid("days") if input.key?("days")

        start_on = start_date(input, nil, today)
        return Input.invalid("start_on") if input.key?("start_on") && start_on.nil?

        name = Input.text(input["companion_name"], 3..120)
        return Input.invalid("companion_name") unless name.is_a?(String)

        kinship = Input.text(input["companion_kinship"], 2..60)
        return Input.invalid("companion_kinship") unless kinship.is_a?(String)
        return Input.invalid("companion_reason") unless COMPANION_REASONS.include?(input["companion_reason"])

        content = { "type" => "companion", "start_on" => start_on&.iso8601, "companion_name" => name,
                    "companion_kinship" => kinship, "companion_reason" => input["companion_reason"],
                    "cid_authorized" => false }.compact
        Result.ok(content: content.merge("note" => note))
      end

      # Início do afastamento ou do acompanhamento: entre hoje − 30 dias e hoje.
      # Ausente: hoje no afastamento, sem a chave no acompanhante.
      def start_date(input, default, today)
        return default unless input.key?("start_on")

        date = Input.date(input["start_on"])
        date&.between?(today - BACKDATE_DAYS, today) ? date : nil
      end
      private_class_method :leave, :companion, :start_date
    end
  end
end
