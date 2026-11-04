// Wrappers with more than one class prop: each goes where the wrapper hands it.
import { Card, CardTitle } from "@/components/ui/card"

export function Panel({ className, titleClassName, footerClassName, children }: any) {
  return (
    <Card className={className}>
      <CardTitle className={titleClassName}>{children}</CardTitle>
      <div className={footerClassName} />
    </Card>
  )
}

export function PassedPanel(props: any) {
  return <Panel {...props} />
}
