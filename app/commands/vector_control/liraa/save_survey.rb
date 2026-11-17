# Cria ou edita o levantamento LIRAa no rascunho (módulo 35a, ADR 0054;
# contrato §7, §12; Q8: o corpo do dashboard). Só a coordenação (quem chama
# confere). Criar: `{ name, starts_on, ends_on, strata? }`; editar: as mesmas
# chaves, todas opcionais, ao menos uma. `strata: [{ name, mode, block_ids }]`
# troca a lista inteira (estratos e quarteirões do rascunho se apagam e
# renascem na ordem dada). Recusas (só a primeira):
#   - chave desconhecida, nome fora de 1–80 (estrato 1–60), data que não é
#     AAAA-MM-DD, fim antes do início, modo fora de LIRAA_MODES, lista vazia
#     ou longa demais, quarteirão que não é UUID, que não existe ou está
#     inativo, ou repetido no estrato → invalid_request com o path
#     (strata[i].block_ids[j] no quarteirão);
#   - quarteirão já em outro estrato do levantamento → stratum_overlap path
#     strata[i].block_ids[j] (a segunda ocorrência);
#   - sob a trava do levantamento (FOR UPDATE), fora de draft →
#     survey_not_draft (409).
# Sem evento (§17).
module VectorControl
  module Liraa
    module SaveSurvey
      KEYS = %w[name starts_on ends_on strata].freeze
      STRATUM_KEYS = %w[name mode block_ids].freeze
      NAME = (1..80)
      STRATUM_NAME = (1..60)
      STRATA_MAX = 50
      BLOCKS_MAX = 5000
      DATE = /\A\d{4}-\d{2}-\d{2}\z/
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      module_function

      # -> Result.ok(survey:) | fail(:invalid_request | :stratum_overlap | :survey_not_draft, details: { path: })
      def call(params:, by:, survey: nil)
        _ = by
        params = params.to_h.stringify_keys
        values = parse(params, survey)
        return values if values.is_a?(Result)

        strata = values.delete(:strata)
        LiraaSurvey.transaction(requires_new: true) do
          if survey
            survey.lock!
            next Result.fail(:survey_not_draft) unless survey.status == "draft"

            starts_on = values.fetch(:starts_on, survey.starts_on)
            next fail_with(:invalid_request, "ends_on") if values.fetch(:ends_on, survey.ends_on) < starts_on

            survey.assign_attributes(values)
            survey.version += 1 if survey.changed? || strata
            survey.save!
          else
            survey = LiraaSurvey.create!(values)
          end
          replace_strata!(survey, strata) if strata
          Result.ok(survey: survey)
        end
      end

      def parse(params, survey)
        unknown = (params.keys - KEYS).first
        return fail_with(:invalid_request, unknown) if unknown
        return fail_with(:invalid_request, nil) if survey && params.empty?

        missing = ((survey ? [] : %w[name starts_on ends_on]) - params.keys).first
        return fail_with(:invalid_request, missing) if missing

        values = {}
        if params.key?("name")
          name = text(params["name"], NAME)
          return fail_with(:invalid_request, "name") unless name

          values[:name] = name
        end
        %w[starts_on ends_on].each do |key|
          next unless params.key?(key)

          date = date(params[key])
          return fail_with(:invalid_request, key) unless date

          values[key.to_sym] = date
        end
        return fail_with(:invalid_request, "ends_on") if !survey && values[:ends_on] < values[:starts_on]

        if params.key?("strata")
          strata = strata(params["strata"])
          return strata if strata.is_a?(Result)

          values[:strata] = strata
        end
        values
      end

      # [{ name:, mode:, block_ids: }] | Result de recusa.
      def strata(raw)
        return fail_with(:invalid_request, "strata") unless raw.is_a?(Array) && raw.size <= STRATA_MAX

        seen = {}
        parsed = raw.each_with_index.map do |stratum, i|
          return fail_with(:invalid_request, "strata[#{i}]") unless stratum.is_a?(Hash)

          stratum = stratum.stringify_keys
          key = (stratum.keys - STRATUM_KEYS).first || (STRATUM_KEYS - stratum.keys).first
          return fail_with(:invalid_request, "strata[#{i}].#{key}") if key

          name = text(stratum["name"], STRATUM_NAME)
          return fail_with(:invalid_request, "strata[#{i}].name") unless name
          return fail_with(:invalid_request, "strata[#{i}].mode") unless Catalog::LIRAA_MODES.include?(stratum["mode"])

          ids = stratum["block_ids"]
          return fail_with(:invalid_request, "strata[#{i}].block_ids") unless ids.is_a?(Array) && ids.size.between?(1, BLOCKS_MAX)

          ids = ids.each_with_index.map do |id, j|
            path = "strata[#{i}].block_ids[#{j}]"
            return fail_with(:invalid_request, path) unless id.is_a?(String) && id.match?(UUID)

            id = id.downcase
            return fail_with(seen[id] == i ? :invalid_request : :stratum_overlap, path) if seen.key?(id)

            seen[id] = i
            id
          end
          { name: name, mode: stratum["mode"], block_ids: ids }
        end
        active = CityBlock.active_blocks.where(id: seen.keys).pluck(:id).to_set
        parsed.each_with_index do |stratum, i|
          j = stratum[:block_ids].index { |id| !active.include?(id) }
          return fail_with(:invalid_request, "strata[#{i}].block_ids[#{j}]") if j
        end
        parsed
      end

      # Apaga os quarteirões e os estratos do rascunho (nessa ordem, a FK) e
      # grava os novos; created_at em microssegundos crescentes fixa a ordem.
      def replace_strata!(survey, strata)
        old = LiraaStratum.where(liraa_survey_id: survey.id)
        LiraaStratumBlock.where(liraa_stratum_id: old.select(:id)).delete_all
        old.delete_all
        now = Time.current
        sequence = 0
        strata.each do |values|
          stratum = LiraaStratum.create!(liraa_survey: survey, name: values[:name], mode: values[:mode],
                                         created_at: now + Rational(sequence += 1, 1_000_000))
          rows = values[:block_ids].map do |id|
            { liraa_stratum_id: stratum.id, liraa_survey_id: survey.id, city_block_id: id,
              created_at: now + Rational(sequence += 1, 1_000_000), updated_at: now }
          end
          LiraaStratumBlock.insert_all!(rows)
        end
      end

      def text(raw, range)
        clean = raw.is_a?(String) ? raw.strip : nil
        clean if clean && range.cover?(clean.length)
      end

      def date(raw)
        raw.is_a?(String) && raw.match?(DATE) && Date.strptime(raw, "%Y-%m-%d")
      rescue Date::Error
        nil
      end

      def fail_with(reason, path) = Result.fail(reason, details: path ? { path: path } : {})
      private_class_method :parse, :strata, :replace_strata!, :text, :date
    end
  end
end
