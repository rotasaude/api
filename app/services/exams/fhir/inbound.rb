# Tradução do DiagnosticReport (ADR 0036, "FHIR só na borda"; contrato §7
# com D7, A7 e A36: amended recusado, reenvio na mesma guia = 200, mesmo
# identifier em outra guia = identifier_conflict, coding SIGTAP = da guia). Valida contra a cópia do esquema (só caminhos no erro, nunca
# valores), confere dom-3 (o esquema não o expressa), o PDF pelos bytes
# (contentEncoding é só anotação), idempotência por (prestador, identifier),
# guia do prestador (de outro = inexistente), paciente por CPF/CNS; chama a
# mesma porta do portal. Nada do recurso vai a log, erro ou exceção.
module Exams
  module Fhir
    module Inbound
      SCHEMA_PATH = Rails.root.join("config/exams/fhir-diagnostic-report-inbound.json")
      CRITICAL = %w[HH LL AA].freeze
      # Recusas da RegisterResult que, aqui, são do recurso (contrato §7).
      RESOURCE_PATHS = { invalid_released_on: "/issued", invalid_laboratory: "/performer" }.freeze

      module_function

      def call(provider:, resource:, now: Time.current)
        return invalid([ "" ]) unless resource.is_a?(Hash)

        paths = schema_paths(resource)
        return Result.fail(:missing_pdf) if paths.include?("/presentedForm")
        return invalid(paths) if paths.any?
        # A36: sem retificação no 21a; recusado antes de qualquer arquivo.
        return Result.fail(:amendment_not_supported) if resource["status"] == "amended"

        # A36: reenvio (mesmo prestador, identifier e guia) é a mesma entrega,
        # mesmo que o resto do recurso não passe mais; outra guia é conflito.
        identifier = resource.dig("identifier", 0, "value")
        short_code = resource.dig("basedOn", 0, "identifier", "value")
        existing = ExamResult.find_by(exam_provider_id: provider.id, fhir_identifier: identifier)
        return resend(existing, short_code) if existing

        observations = resource["contained"]
        refs = resource["result"].map { |r| r["reference"].delete_prefix("#") }
        return invalid([ "/result" ]) unless refs.sort == observations.map { |o| o["id"] }.sort

        issued = issued_at(resource["issued"])
        return invalid([ "/issued" ]) unless issued && issued.in_time_zone.to_date <= now.in_time_zone.to_date

        pdf = decode_pdf(resource.dig("presentedForm", 0, "data"))
        return Result.fail(:missing_pdf) unless pdf

        order = ExamOrder.find_by(short_code: short_code, exam_provider_id: provider.id)
        return Result.fail(:order_not_found) unless order
        return Result.fail(:patient_mismatch) unless Identifiers.matches?(order.patient, resource.dig("subject", "identifier"))
        return invalid([ "/code" ]) unless sigtap_matches?(resource["code"], order)

        stored = Files.store(bytes: pdf, content_type: "application/pdf", provider: provider)
        return Result.fail(:missing_pdf) if stored.failure?

        registered = RegisterResult.call(
          order: order, source: "fhir", file: stored.payload[:file], released_on: issued.in_time_zone.to_date,
          laboratory_name: resource.dig("performer", 0, "display"), critical: critical?(observations),
          values: ResultValues.from_fhir(order.catalog_item, observations), by_provider: provider,
          fhir_identifier: identifier, now: now
        )
        return Result.ok(result: registered.payload[:result], created: true) if registered.ok?

        translate(registered, provider, identifier, short_code)
      rescue ActiveRecord::RecordNotUnique
        again = ExamResult.find_by(exam_provider_id: provider.id, fhir_identifier: identifier)
        again ? resend(again, short_code) : raise
      end

      # Mesma guia → 200 com o resultado existente; outra → 409.
      def resend(existing, short_code)
        return Result.fail(:identifier_conflict) unless existing.exam_order&.short_code == short_code

        Result.ok(result: existing, created: false)
      end

      # A36: só o coding do sistema SIGTAP é conferido; sem ele, passa.
      def sigtap_matches?(code, order)
        Array(code["coding"]).select { |c| c["system"] == ServiceRequests::SIGTAP_SYSTEM }.all? { |c| c["code"] == order.sigtap_code }
      end

      # Corrida: a segunda entrega do MESMO identifier serializa em
      # order.lock! e encontra o resultado da primeira — é a mesma entrega
      # (ou conflito, se de outra guia: A36). Outro identifier numa guia que
      # já tem resultado: a guia já não está em agendado/coletado (409).
      def translate(failure, provider, identifier, short_code)
        case failure.reason
        when :result_already_registered
          existing = ExamResult.find_by(exam_provider_id: provider.id, fhir_identifier: identifier)
          existing ? resend(existing, short_code) : Result.fail(:invalid_transition)
        when *RESOURCE_PATHS.keys then invalid([ RESOURCE_PATHS.fetch(failure.reason) ])
        else failure
        end
      end

      # Só o primeiro segmento do ponteiro (sempre um nome do esquema); o
      # `required` na raiz vira o caminho de cada chave ausente.
      def schema_paths(resource)
        schema.validate(resource).flat_map do |error|
          pointer = error["data_pointer"].to_s
          if pointer.empty? && error["type"] == "required"
            Array(error.dig("details", "missing_keys")).map { |key| "/#{key}" }
          else
            [ "/" + pointer.delete_prefix("/").split("/").first.to_s ]
          end
        end.uniq.sort.first(20)
      end

      def critical?(observations)
        observations.any? { |o| Array(o["interpretation"]).flat_map { |i| Array(i["coding"]) }.any? { |c| CRITICAL.include?(c["code"]) } }
      end

      # Base64 estrito e bytes mágicos de PDF; nil em qualquer outro caso.
      def decode_pdf(data)
        bytes = Base64.strict_decode64(data.to_s).b
        bytes.start_with?(Files::MAGIC.fetch("application/pdf")) && bytes.bytesize <= Files::MAX_BYTES ? bytes : nil
      rescue ArgumentError
        nil
      end

      def issued_at(raw)
        Time.iso8601(raw.to_s)
      rescue ArgumentError
        nil
      end

      def invalid(paths) = Result.fail(:invalid_resource, details: { paths: paths })

      def schema = (@schema ||= JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH))))
      private_class_method :translate, :resend, :sigtap_matches?, :schema_paths, :critical?, :decode_pdf, :issued_at, :invalid, :schema
    end
  end
end
