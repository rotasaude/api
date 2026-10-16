# Carimbo de linha do laboratório (I1 da revisão da Task 17), tomado DEPOIS
# da trava da requisição. A fila de críticos (Lab::Criticals) decide "a linha
# que valia no laudo" por `created_at <= lr.created_at`: uma linha que esperou
# a trava enquanto um laudo nascia precisa ficar DEPOIS dele. Por isso, além
# do relógio lido agora (nunca um `now` capturado antes de esperar), a linha
# fica estritamente depois do laudo mais novo da requisição — garantia que não
# depende do relógio de cada host do app (nem do banco, que o travel dos
# testes não alcança).
module Lab
  module Clock
    module_function

    def stamp(now, requisition_id:)
      at = [ now, Time.current ].max.round(6)
      last = LabReport.where(lab_requisition_id: requisition_id).maximum(:created_at)
      last && at <= last ? last + Rational(1, 1_000_000) : at
    end
  end
end
