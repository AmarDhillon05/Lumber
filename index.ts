import { registerRootComponent } from 'expo';
import { installCrashHandler, reportCrash, toCrashInfo, withCrashScreen } from './src/crash/CrashScreen';

// Release builds close silently on a JS error; show it on screen instead.
installCrashHandler();

// Load the app inside try/catch so an error thrown while any screen's module
// loads (e.g. a native module missing from this build) is shown, not fatal.
let App: () => any;
try {
  App = require('./App').default;
} catch (e) {
  reportCrash(toCrashInfo(e, 'while starting up'));
  App = () => null;
}

// registerRootComponent calls AppRegistry.registerComponent('main', () => App).
registerRootComponent(withCrashScreen(App));
