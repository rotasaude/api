# app/services/clinical_documents/content/controlled.rb
# Categoria da receita e as regras de cada uma (ADR 0034; spec §5; Portaria
# 344/1998 arts. 52, 57, 59; RDC 471/2021; Valores fixados 3–4; esquema
# clinical-v1.2.0 apertado pelo usuário em 2026-10-10). A categoria sai dos
# itens do catálogo: controle especial se houver C1/C5, senão antimicrobiano
# se houver antimicrobiano, senão comum. RCE só com C1/C5 do catálogo (nenhum
# antimicrobiano); RET só com antimicrobianos do catálogo (texto livre não
# recebe número SNCR sem conferência do catálogo); o que não serve à categoria
# dominante é recusado com o índice (vira outra receita). Receita só de texto
# livre antimicrobiano não vira RET (fix round 1, coordenador, §12): sai
# `paper_only`, pelo caminho da receita antimicrobiana em papel do 19c (o mesmo
# de `legacy`; a emissão a leva a papel sem tirar número). Controlado em texto
# livre, listas A/B (notificação) e C2/C3/C4 são recusados antes; lista
# desconhecida falha fechada. Desligado o interruptor, `legacy` repete o 19c.
module ClinicalDocuments
  module Content
    module Controlled
      SPECIAL = %w[C1 C5].freeze
      NOTIFICATION = %w[A1 A2 A3 B1 B2].freeze
      UNSUPPORTED = %w[C2 C3 C4].freeze
      MAX_C1 = 3
      SPECIAL_DAYS = 60
      ANTICONVULSANT_DAYS = 180
      VALIDITY = { "special_control" => 30, "antimicrobial" => 10 }.freeze
      PRESCRIBERS = %i[physician dentist].freeze

      module_function

      def classify(items)
        items.each_with_index do |it, index|
          reason = refusal(it)
          return Result.fail(reason, details: { index: index }) if reason
        end
        category = if items.any? { |it| special?(it) } then "special_control"
        elsif items.any? { |it| it[:antimicrobial] } then "antimicrobial"
        else "common"
        end
        paper_only = category == "antimicrobial" && items.all? { |it| it[:catalog].nil? }
        index = paper_only ? nil : items.index { |it| !fits?(category, it) }
        index ? Result.fail(:mixed_categories, details: { index: index }) : Result.ok(category: category, paper_only: paper_only)
      end

      def legacy(items)
        items.each_with_index { |it, index| return Result.fail(:controlled_not_allowed, details: { index: index }) if it[:controlled] }
        Result.ok(category: items.any? { |it| it[:antimicrobial] } ? "antimicrobial" : "common")
      end

      def check(category, items, role:, identification:, prescriber_contact:, patient:)
        case category
        when "special_control" then special(items, role, identification, prescriber_contact, patient)
        when "antimicrobial"
          identified = PatientIdentification.call(identification, required: false, patient: patient)
          return identified if identified.failure?

          Result.ok(patient_identification: identified.payload[:value], prescriber_contact: (prescriber_contact unless role == :nurse))
        else
          Result.ok(patient_identification: nil, prescriber_contact: nil)
        end
      end

      def validity(category, today) = VALIDITY.key?(category) ? today + VALIDITY.fetch(category) : nil

      def refusal(it)
        return nil unless it[:controlled]
        return :controlled_not_allowed if it[:free_text]
        return :requires_notification if NOTIFICATION.include?(it[:controlled_list])

        SPECIAL.include?(it[:controlled_list]) ? nil : :not_supported
      end

      def special?(it) = !it[:catalog].nil? && SPECIAL.include?(it[:controlled_list])

      def fits?(category, it)
        case category
        when "special_control" then special?(it) && !it[:antimicrobial]
        when "antimicrobial" then !it[:catalog].nil? && it[:antimicrobial] == true
        else true
        end
      end

      def special(items, role, identification, prescriber_contact, patient)
        return Result.fail(:cbo_not_allowed) unless PRESCRIBERS.include?(role)
        return Result.fail(:too_many_c1_substances) if items.count { |it| it[:controlled_list] == "C1" } > MAX_C1

        items.each_with_index do |it, index|
          return Result.fail(:invalid_item, details: { index: index, field: "duration_days" }) if it[:duration_days].nil?

          limit = it[:anticonvulsant] ? ANTICONVULSANT_DAYS : SPECIAL_DAYS
          return Result.fail(:duration_exceeded, details: { index: index }) if it[:duration_days] > limit
        end
        identified = PatientIdentification.call(identification, required: true, patient: patient)
        return identified if identified.failure?
        return Result.fail(:prescriber_address_missing) unless prescriber_contact

        Result.ok(patient_identification: identified.payload[:value], prescriber_contact: prescriber_contact)
      end
      private_class_method :refusal, :special?, :fits?, :special
    end
  end
end
