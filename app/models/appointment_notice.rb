# Aviso de lembrete na caixa do cidadão (ADR 0029 §6; contratos §5, §8). Só a
# primeira leitura é gravada (trigger); a exclusão do cadastro apaga.
class AppointmentNotice < ApplicationRecord
  belongs_to :appointment
  belongs_to :citizen
end
