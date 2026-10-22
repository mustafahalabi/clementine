import {loadFont as loadInter} from '@remotion/google-fonts/Inter';
import {loadFont as loadTight} from '@remotion/google-fonts/InterTight';
export const inter = loadInter('normal', {weights: ['400', '500', '600', '700'], subsets: ['latin']}).fontFamily;
export const tight = loadTight('normal', {weights: ['500', '600', '700', '800'], subsets: ['latin']}).fontFamily;
