import Foundation

let paragraphs: [DocxExporter.Paragraph] = [
    DocxExporter.Paragraph([
        DocxExporter.Run(text: "before "),
        DocxExporter.Run(text: "BOLD", bold: true)
    ]),
    DocxExporter.Paragraph([
        DocxExporter.Run(text: "BOLD2", bold: true)
    ]),
    DocxExporter.Paragraph([
        DocxExporter.Run(text: "before2 "),
        DocxExporter.Run(text: "BOLD3", bold: true),
        DocxExporter.Run(text: " after3")
    ])
]

let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
try DocxExporter.write(paragraphs: paragraphs, to: outURL)
print("wrote")
