# Chamada do atendimento (ADR 0050; plano, Desvio 12): cada chamada para a
# classificação ou o atendimento, com a senha do momento e o local. Só
# acréscimo (trigger). A TV lê só senha, local, tipo e hora.
class AttendanceCall < ApplicationRecord
  belongs_to :attendance
  belongs_to :call_location, optional: true
  belongs_to :called_by_user, class_name: "User"
end
