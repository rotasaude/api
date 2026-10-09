# Leitura administrativa de uma consulta finalizada pelo municipal_admin
# (Task 23 do módulo 19; decisão do usuário 2026-10-09): guardada para sempre,
# fonte do item administrative_read do relatório das aberturas. Só acréscimo
# (o banco recusa UPDATE/DELETE/TRUNCATE).
class ClinicalRecordAdministrativeRead < ApplicationRecord
  belongs_to :user
  belongs_to :patient
  belongs_to :consultation

  def readonly? = persisted?
end
