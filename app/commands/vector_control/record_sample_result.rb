# Resultado da amostra de larvas (módulo 35a, ADR 0054; contrato §9, §17; Q9,
# Q23, Q24(2)). Pela coordenação (endemic_coordinator) ou pelo laboratório
# (vector_lab); senão missing_role. `params` = `{ examined_larvae,
# aegypti_larvae, albopictus_larvae, result_note? }`. Recusas (só a primeira):
#   - número ausente, não inteiro ou negativo → invalid_request com o path do
#     campo; nota que não é texto → invalid_request path result_note;
#   - sob a trava (visita FOR SHARE → amostra FOR UPDATE; a retirada trava a
#     visita FOR UPDATE e nunca a amostra): visita retirada → not_found;
#   - examined_larvae > larvae_collected → sample_result_invalid path
#     examined_larvae; aegypti + albopictus > examined → sample_result_invalid
#     path aegypti_larvae;
#   - primeiro resultado com nota → invalid_request path result_note (a nota
#     é só da correção; o banco recusa, e texto nunca some calado);
#   - correção (a amostra já tem resultado): nota ausente ou fora de 10–500
#     depois do strip → invalid_request path result_note (Q9); os mesmos três
#     números → invalid_request path examined_larvae (só a nota mudaria: não
#     é correção, como a Q23 da contagem); a mesma nota da correção anterior
#     → invalid_request path result_note. A comparação é em TEXTO CLARO: a
#     cifra não determinística muda a cada gravação, então o trigger (que
#     compara a cifra) não pega a repetição.
# Concorrência otimista (Q36, docs e7720b6; a forma do SaveParameters/Q34):
# `params["expected_version"]` é a version da amostra que a tela leu. Fora
# de inteiro >= 0 → invalid_request path expected_version (antes da trava).
# Sob a trava, numa correção: ausente → expected_version_required, diferente
# da version da linha travada → sample_changed (409), nada gravado e nenhum
# evento; a tela relê. No primeiro resultado não há versão a conferir:
# mandá-la → invalid_request path expected_version (a mesma regra da nota no
# primeiro resultado). Esta conferência vem depois de sample_result_invalid
# (que só lê larvae_collected, imutável) e antes das recusas do conteúdo da
# correção. Toda escrita da amostra sobe a version (criação = 1, resultado e
# correção = + 1).
# Grava os três números, result_at, quem lançou, a nota (cifrada com a chave
# da cidade; nil no primeiro) e version + 1; `vector_sample.result_recorded`
# com `corrected`. O índice do LIRAa lê o resultado na hora (Q24(2)). A nota
# nunca sai em log, evento, erro nem JSON.
module VectorControl
  module RecordSampleResult
    EVENT = "vector_sample.result_recorded".freeze
    COUNTS = %w[examined_larvae aegypti_larvae albopictus_larvae].freeze

    module_function

    # -> Result.ok(sample:) | fail(<código>, details: { path: })
    #    | fail(:expected_version_required, details: { path: "expected_version" }) | fail(:sample_changed)
    def call(sample:, params:, by:, now: Time.current)
      return Result.fail(:missing_role) unless Access.coordinator?(by) || Access.lab?(by)

      counts = COUNTS.to_h { |key| [ key, params[key] ] }
      bad = COUNTS.find { |key| !(counts[key].is_a?(Integer) && counts[key] >= 0) }
      return invalid(bad) if bad

      note = params["result_note"]
      return invalid("result_note") unless note.nil? || note.is_a?(String)

      expected = params["expected_version"]
      return invalid("expected_version") unless expected.nil? || (expected.is_a?(Integer) && expected >= 0)

      VectorSample.transaction(requires_new: true) { write(sample, counts, note&.strip, by, now, expected) }
    end

    def write(sample, counts, note, by, now, expected_version)
      inspection = VectorInspection.find(sample.vector_inspection_id)
      visit = HomeVisit.lock("FOR SHARE").find(inspection.home_visit_id)
      return Result.fail(:not_found) if visit.withdrawn_at

      sample.lock!
      refusal = bounds_refusal(sample, counts)
      return Result.fail(:sample_result_invalid, details: { path: refusal }) if refusal

      corrected = !sample.result_at.nil?
      if corrected
        return Result.fail(:expected_version_required, details: { path: "expected_version" }) if expected_version.nil?
        return Result.fail(:sample_changed) unless expected_version == sample.version
      elsif !expected_version.nil?
        return invalid("expected_version")
      end

      refusal = corrected ? correction_refusal(sample, counts, note) : (note.nil? ? nil : "result_note")
      return invalid(refusal) if refusal

      sample.update!(**counts.transform_keys(&:to_sym), result_at: now, result_by_user: by,
                     result_note: corrected ? note : nil, version: sample.version + 1)
      DomainEvents.publish(EVENT, vector_sample_id: sample.id, user_id: by.id, corrected: corrected)
      Result.ok(sample: sample)
    end

    # O path de sample_result_invalid, ou nil.
    def bounds_refusal(sample, counts)
      return "examined_larvae" if counts["examined_larvae"] > sample.larvae_collected
      return "aegypti_larvae" if counts["aegypti_larvae"] + counts["albopictus_larvae"] > counts["examined_larvae"]

      nil
    end

    # O path da recusa da correção, ou nil.
    def correction_refusal(sample, counts, note)
      return "result_note" unless note && Catalog::NOTE.cover?(note.length)
      return "examined_larvae" if COUNTS.all? { |key| sample.public_send(key) == counts[key] }
      return "result_note" if note == sample.result_note

      nil
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
  end
end
