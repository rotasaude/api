# Auditoria/backfill do bug de scoring ponderado corrigido em 8e1a9dc.
#
# Antes da correção, Protocols::Protocol#evaluate montava o trail só com
# {step, answer}; Protocols::Scoring::Weighted#call soma entry[:weight], então
# todo protocolo "weighted" pontuava 0 e caía no tier mais baixo. As triagens
# concluídas ANTES da correção têm triage.outcome com score errado (0/ausente)
# e, possivelmente, tier/priority incorretos.
#
# Esta task recalcula cada triagem concluída de protocolo weighted usando o MOTOR
# JÁ CORRIGIDO, a partir da própria definição da triagem, e compara com o que foi
# persistido. É dry-run por padrão; passe APPLY=1 para gravar as correções.
#
# Conexão: usa o papel :admin (BYPASSRLS) — opera sobre todos os municípios.
#
#   bin/rails triage:audit_weighted_scoring            # relatório (dry-run)
#   APPLY=1 bin/rails triage:audit_weighted_scoring    # aplica o backfill
namespace :triage do
  desc "Audita (e opcionalmente corrige com APPLY=1) triagens weighted afetadas pelo bug de scoring (8e1a9dc)."
  task audit_weighted_scoring: :environment do
    apply = ENV["APPLY"] == "1"

    ApplicationRecord.connected_to(role: :admin) do
      weighted_def_ids = ProtocolDefinition
        .where("definition -> 'scoring' ->> 'type' = ?", "weighted")
        .pluck(:id)

      scope = Triage.where(status: "completed", protocol_definition_id: weighted_def_ids)

      total      = scope.count
      changed    = 0
      unchanged  = 0
      errored    = 0

      puts "[audit] modo: #{apply ? 'APPLY (gravando)' : 'dry-run (somente relatório)'}"
      puts "[audit] definições weighted: #{weighted_def_ids.size} | triagens weighted concluídas: #{total}"
      puts "-" * 88

      scope.includes(:protocol_definition).find_each do |t|
        protocol = Protocols::Definitions.build(t.protocol_definition.definition)

        # Fonte da verdade das respostas: a coluna answers; se vazia, reconstrói
        # a partir do trail persistido (step -> answer).
        answers = t.answers.presence || rebuild_answers_from_trail(t.outcome)
        recomputed = protocol.evaluate(answers)

        old_tier  = t.tier
        old_prio  = t.priority
        old_score = t.outcome.is_a?(Hash) ? t.outcome["score"] : nil

        tier_diff  = old_tier  != recomputed.tier
        prio_diff  = old_prio  != recomputed.priority
        score_diff = old_score != recomputed.score

        if tier_diff || prio_diff || score_diff
          changed += 1
          flag = tier_diff ? "TIER/PRIORITY MUDA ⚠" : "só score/trail"
          puts format(
            "triage=%s [%s]\n  tier:     %-12s -> %-12s\n  priority: %-12s -> %-12s\n  score:    %-12s -> %-12s",
            t.id, flag,
            old_tier.inspect, recomputed.tier.inspect,
            old_prio.inspect, recomputed.priority.inspect,
            old_score.inspect, recomputed.score.inspect
          )

          if apply
            t.update_columns(
              tier:     recomputed.tier,
              priority: recomputed.priority,
              outcome:  recomputed.to_h
            )
            puts "  -> gravado."
          end
        else
          unchanged += 1
        end
      rescue => e
        errored += 1
        warn "triage=#{t.id} ERRO: #{e.class}: #{e.message}"
      end

      puts "-" * 88
      puts "[audit] total=#{total} alterar=#{changed} inalteradas=#{unchanged} erros=#{errored}"
      puts "[audit] dry-run: nada foi gravado. Rode com APPLY=1 para aplicar." unless apply
    end
  end

  # Trail persistido é um array de hashes com chaves string ("step","answer").
  def rebuild_answers_from_trail(outcome)
    trail = outcome.is_a?(Hash) ? outcome["trail"] : nil
    return {} unless trail.is_a?(Array)
    trail.each_with_object({}) { |e, acc| acc[e["step"].to_s] = e["answer"] }
  end
end
