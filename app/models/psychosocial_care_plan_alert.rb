# Aviso de revisão vencida do PTS (ADR 0049): um por versão, só acréscimo
# (trigger) — o job diário não avisa duas vezes a mesma versão.
class PsychosocialCarePlanAlert < ApplicationRecord
  belongs_to :psychosocial_care_plan
end
