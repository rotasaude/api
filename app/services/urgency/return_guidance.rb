# Textos da orientação de retorno à UBS (ADR 0050; contrato §14 Q13, Q26): um
# lugar só para "1 dia" no singular e "N dias" de 2 em diante. `note` é a do
# profissional (a nota de encaminhamento do 13 e a linha do tempo, onde o
# motivo vem depois); `citizen` é a do cidadão, nunca com o motivo.
module Urgency
  module ReturnGuidance
    module_function

    def days(count) = "#{count} #{count == 1 ? 'dia' : 'dias'}"
    def note(count) = "Retorno à UBS em até #{days(count)}"
    def citizen(count) = "Procure a sua UBS em até #{days(count)}"
  end
end
