import { BridgeMessage } from '../api/BridgeMessage';
import { TrustedPageContext } from '../api/TrustedPageContext';

/**
 * 与 Page 实现解耦的上下文注入点：内核在收到消息时调用它派生 TrustedPageContext，
 * 使 origin 由内核侧派生而非宿主逐条声明。与 Android 的 PageContextProvider 等价。
 * 未注入时退化为 processIncomingResponses(messageJson, origin) 的宿主声明路径。
 */
export interface PageContextProvider {
  createContext(message: BridgeMessage, pageInstanceId: string): TrustedPageContext;
}
