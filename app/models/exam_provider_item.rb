# Exame que um prestador faz, com prazos próprios (sobrepõem os do catálogo).
class ExamProviderItem < ApplicationRecord
  belongs_to :exam_provider
  belongs_to :exam_catalog_item

  def days_for(stage) = public_send(:"#{stage}_days")
end
