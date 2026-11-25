# app/models/obm_presentation.rb
# Uma apresentação (AMPP) do OBM (módulo 27b; contrato Q12). Nunca apagada: a
# que sai do arquivo fica `active = false`. O VMP do item do catálogo sai do
# CATMAT desta linha; a apresentação sem item ativo do catálogo é a lista de
# revisão (`unmatched`).
class ObmPresentation < PlatformRecord
  scope :active, -> { where(active: true) }

  # CATMAT em branco, ou sem item ativo no catálogo.
  scope :unmatched, lambda {
    active.where("NOT EXISTS (SELECT 1 FROM medication_catalog_items i " \
                 "WHERE i.catmat_code = obm_presentations.catmat_code AND i.status = 'active')")
  }
end
