# Conta os ovos da palheta (módulo 35a, ADR 0054; contrato §6, §11, §17; Q9;
# A-8). Pela coordenação (endemic_coordinator) ou pelo laboratório
# (vector_lab); senão missing_role. Recusas (só a primeira):
#   - egg_count não inteiro ou fora de 0–9999 → invalid_request path egg_count;
#   - sob a trava (ovitrampa → leitura, a ordem do CollectOvitrap): leitura
#     não coletada ou condition ≠ ok → reading_not_countable;
#   - primeira contagem com nota → invalid_request path count_note (a nota é
#     só da correção; o banco recusa, e texto nunca some calado);
#   - correção (a leitura já tem contagem): nota ausente ou fora de 10–500
#     depois do strip → invalid_request path count_note (Q9); a mesma
#     contagem → invalid_request path egg_count (só a nota mudaria: não é
#     correção); a mesma nota da contagem anterior → invalid_request path
#     count_note. A comparação é em TEXTO CLARO: a cifra não determinística
#     muda a cada gravação, então o trigger (que compara a cifra) não pega a
#     repetição.
# Concorrência otimista (Q36, docs e7720b6; a forma do SaveParameters/Q34):
# a correção leva `expected_version`, a version da leitura que a tela leu.
# Fora de inteiro >= 0 → invalid_request path expected_version (antes da
# trava). Sob a trava, numa correção: ausente → expected_version_required,
# diferente da version da linha travada → reading_changed (409), nada
# gravado e nenhum evento; a tela relê. Na primeira contagem não há versão a
# conferir: mandá-la → invalid_request path expected_version (a mesma regra
# da nota na primeira contagem: nada some calado). Esta conferência vem antes
# das recusas do conteúdo da correção. Toda escrita da leitura sobe a
# version (instalação = 1, coleta, contagem e correção = + 1).
# Grava egg_count, counted_at, quem contou, a nota (cifrada com a chave da
# cidade) e version + 1; `ovitrap_reading.counted` com `corrected`. Contagem
# ≥ ovitrap_alert_eggs (Parameters.current) abre a tarefa
# ovitrap_intensification da ovitrampa com suggested_block_ids =
# Rings.around([quarteirão da ovitrampa], rings: ovitrap_radius_rings) e
# `vector_task.opened`, salvo já haver uma aberta da ovitrampa (travada FOR
# UPDATE: a contagem é absorvida, sem evento; A-8). A nota nunca sai em log,
# evento, erro nem JSON.
module VectorControl
  module CountReading
    EVENT = "ovitrap_reading.counted".freeze
    TASK_EVENT = "vector_task.opened".freeze
    TASK_KIND = "ovitrap_intensification".freeze

    module_function

    # -> Result.ok(reading:, task:) (task = a tarefa aberta agora, ou nil) | fail(<código>, details: { path: })
    #    | fail(:expected_version_required, details: { path: "expected_version" }) | fail(:reading_changed)
    def call(reading:, egg_count:, note:, by:, expected_version: nil, now: Time.current)
      return Result.fail(:missing_role) unless Access.coordinator?(by) || Access.lab?(by)
      return invalid("egg_count") unless egg_count.is_a?(Integer) && Catalog::EGGS.cover?(egg_count)
      return invalid("count_note") unless note.nil? || note.is_a?(String)
      return invalid("expected_version") unless expected_version.nil? || (expected_version.is_a?(Integer) && expected_version >= 0)

      OvitrapReading.transaction(requires_new: true) { write(reading, egg_count, note&.strip, by, now, expected_version) }
    end

    def write(reading, egg_count, note, by, now, expected_version)
      ovitrap = Ovitrap.lock.find(reading.ovitrap_id)
      reading.lock!
      return Result.fail(:reading_not_countable) unless reading.collected_on && reading.condition == "ok"

      corrected = !reading.egg_count.nil?
      if corrected
        return Result.fail(:expected_version_required, details: { path: "expected_version" }) if expected_version.nil?
        return Result.fail(:reading_changed) unless expected_version == reading.version
      elsif !expected_version.nil?
        return invalid("expected_version")
      end

      refusal = corrected ? correction_refusal(reading, egg_count, note) : (note.nil? ? nil : "count_note")
      return invalid(refusal) if refusal

      reading.update!(egg_count: egg_count, counted_at: now, counted_by_user: by, count_note: corrected ? note : nil,
                      version: reading.version + 1)
      DomainEvents.publish(EVENT, ovitrap_reading_id: reading.id, user_id: by.id, corrected: corrected)
      Result.ok(reading: reading, task: alert!(ovitrap, reading))
    end

    # O path da recusa da correção, ou nil.
    def correction_refusal(reading, egg_count, note)
      return "count_note" unless note && Catalog::NOTE.cover?(note.length)
      return "egg_count" if egg_count == reading.egg_count
      return "count_note" if note == reading.count_note

      nil
    end

    def alert!(ovitrap, reading)
      values = Parameters.current.values
      return nil if reading.egg_count < values.fetch("ovitrap_alert_eggs")
      return nil if VectorTask.open_tasks.where(kind: TASK_KIND, ovitrap_id: ovitrap.id).lock.first

      blocks = Rings.around([ ovitrap.city_block_id ], rings: values.fetch("ovitrap_radius_rings"))
      task = VectorTask.create!(kind: TASK_KIND, ovitrap_reading: reading, ovitrap_id: ovitrap.id, suggested_block_ids: blocks)
      DomainEvents.publish(TASK_EVENT, vector_task_id: task.id)
      task
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
  end
end
